#!/usr/bin/env ruby
# frozen_string_literal: true

# Books an Envoy desk for a range of weekdays by replaying the same private
# API calls Envoy's own web dashboard makes (Envoy has no public API and no
# recurring-booking feature). See README.md for the full protocol writeup.
#
# Auth is never a CLI flag: the session cookie and CSRF token are read from
# ENVOY_COOKIE / ENVOY_CSRF_TOKEN so they never end up in shell history, a
# process list, or a script file that could be committed.

require 'net/http'
require 'json'
require 'optparse'
require 'time'
require 'date'

INVITES_URL = URI('https://app.envoy.com/a/visitors/api/v3/invites')
RESERVATIONS_URL = URI('https://app.envoy.com/a/rms/reservations')
desk_reservations_url = ->(desk_id) { URI("https://app.envoy.com/a/rms/desks/#{desk_id}/reservations") }

def die(msg)
  warn "error: #{msg}"
  exit 1
end

options = {
  include_weekends: false,
  delay: 0.4,
  auth_retries: 4,
  auth_retry_wait: 4,
  stop_after_consecutive_failures: 6,
}

OptionParser.new do |opts|
  opts.banner = "Usage: book_desk.rb [options]\n\n" \
                "Auth (required, via environment, never as flags):\n" \
                "  ENVOY_COOKIE       full Cookie header value from a logged-in browser tab\n" \
                "  ENVOY_CSRF_TOKEN   value of the csrf_token cookie\n" \
                "See README.md for how to extract these.\n\n"

  opts.on('--location-id ID', 'Envoy location id (required)') { |v| options[:location_id] = v }
  opts.on('--desk-id ID', 'Desk id to book (required)') { |v| options[:desk_id] = v }
  opts.on('--user-id ID', 'Envoy user id (required)') { |v| options[:user_id] = v }
  opts.on('--company-id ID', 'Envoy company id (required)') { |v| options[:company_id] = v }
  opts.on('--flow-id ID', 'Invite flow id, e.g. "Employee registration" (required)') { |v| options[:flow_id] = v }
  opts.on('--full-name NAME', 'Full name on the invite (required)') { |v| options[:full_name] = v }
  opts.on('--email EMAIL', 'Email on the invite (required)') { |v| options[:email] = v }
  opts.on('--start-date DATE', 'First date to book, YYYY-MM-DD (required)') { |v| options[:start_date] = v }
  opts.on('--end-date DATE', 'Last date to book, YYYY-MM-DD, inclusive (required)') { |v| options[:end_date] = v }
  opts.on('--include-weekends', 'Book Sat/Sun too (default: weekdays only)') { options[:include_weekends] = true }
  opts.on('--delay SECONDS', Float, 'Pause between days (default: 0.4)') { |v| options[:delay] = v }
  opts.on('--dry-run', "Print the target dates and exit without booking") { options[:dry_run] = true }
end.parse!

%i[location_id desk_id user_id company_id flow_id full_name email start_date end_date].each do |key|
  die "missing required option --#{key.to_s.tr('_', '-')}" unless options[key]
end

cookie = ENV['ENVOY_COOKIE']
csrf_token = ENV['ENVOY_CSRF_TOKEN']
die 'ENVOY_COOKIE is not set (see README.md)' if !cookie && !options[:dry_run]
die 'ENVOY_CSRF_TOKEN is not set (see README.md)' if !csrf_token && !options[:dry_run]

start_date = begin
  Date.parse(options[:start_date])
rescue ArgumentError
  die "--start-date must be YYYY-MM-DD"
end
end_date = begin
  Date.parse(options[:end_date])
rescue ArgumentError
  die "--end-date must be YYYY-MM-DD"
end
die '--start-date must be on or before --end-date' if start_date > end_date

envoy_context = JSON.generate(
  fe_name: 'dashboard',
  scope: 'location',
  location_id: options[:location_id],
  user_id: options[:user_id],
  company_id: options[:company_id]
)

def request(uri, method: :get, headers: {}, body: nil, cookie:)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = case method
        when :get then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        end
  req['cookie'] = cookie
  headers.each { |k, v| req[k] = v }
  req.body = body if body

  http.request(req)
end

# Local midnight and local 23:59:00 for `date`, as epoch seconds — matches
# what Envoy's own frontend sends for the reservation window.
def day_bounds_epoch(date)
  start_t = Time.new(date.year, date.month, date.day, 0, 0, 0)
  end_t = Time.new(date.year, date.month, date.day, 23, 59, 0)
  [start_t.to_i, end_t.to_i]
end

# Local midnight and local 23:59:59 for `date`, as ISO8601 — used only to
# frame the invite-lookup filter window, not sent to the reservation POST.
def day_bounds_iso(date)
  start_t = Time.new(date.year, date.month, date.day, 0, 0, 0)
  end_t = Time.new(date.year, date.month, date.day, 23, 59, 59)
  [start_t.iso8601, end_t.iso8601]
end

def auth_failure?(response)
  %w[401 403].include?(response.code)
end

# Books (or confirms) a single day. Returns a status string.
def book_day(date, options, envoy_context, cookie, csrf_token, desk_reservations_url)
  start_ts, end_ts = day_bounds_epoch(date)
  iso_from, iso_to = day_bounds_iso(date)
  arrival_iso = Time.at(start_ts).utc.iso8601(3)

  # 1. Does an invite already exist for this date?
  check_uri = URI(INVITES_URL)
  check_uri.query = URI.encode_www_form(
    'filter[location]' => options[:location_id],
    'filter[email]' => options[:email],
    'filter[employee-centric]' => 'true',
    'filter[datetime-from]' => iso_from,
    'filter[datetime-to]' => iso_to
  )
  check_resp = request(
    check_uri,
    headers: { 'accept' => 'application/json; charset=utf-8, application/vnd.api+json' },
    cookie: cookie
  )
  return ["FAILED invite check (#{check_resp.code})", nil] unless check_resp.is_a?(Net::HTTPSuccess)

  existing_invites = (JSON.parse(check_resp.body)['data'] || [])

  # 2. Is the desk already reserved for you on this date?
  desk_uri = URI(desk_reservations_url.call(options[:desk_id]))
  desk_uri.query = URI.encode_www_form('filter[start-time]' => start_ts, 'filter[end-time]' => end_ts)
  desk_resp = request(desk_uri, headers: { 'accept' => 'application/vnd.api+json' }, cookie: cookie)
  if desk_resp.is_a?(Net::HTTPSuccess)
    existing_reservations = (JSON.parse(desk_resp.body)['data'] || [])
    already_yours = existing_reservations.any? do |r|
      r.dig('relationships', 'user', 'data', 'id') == options[:user_id]
    end
    return ['already booked - skipped', nil] if already_yours
  end

  # 3. Create the invite if needed. CSRF token is read fresh by the caller
  # each call, since Envoy rotates it after every mutation.
  invite_id = existing_invites.first&.fetch('id', nil)
  unless invite_id
    invite_body = JSON.generate(
      data: {
        type: 'invites',
        attributes: {
          'expected-arrival-time' => arrival_iso,
          'full-name' => options[:full_name],
          'email' => options[:email],
        },
        relationships: {
          location: { data: { type: 'locations', id: options[:location_id] } },
          flow: { data: { type: 'flows', id: options[:flow_id] } },
        }
      }
    )
    invite_resp = request(
      INVITES_URL,
      method: :post,
      headers: {
        'content-type' => 'application/vnd.api+json',
        'x-csrf-token' => csrf_token,
        'x-envoy-context' => envoy_context,
      },
      body: invite_body,
      cookie: cookie
    )
    unless invite_resp.is_a?(Net::HTTPSuccess)
      return ["FAILED creating invite (#{invite_resp.code}): #{invite_resp.body.to_s[0, 250]}", invite_resp]
    end
    invite_id = JSON.parse(invite_resp.body).dig('data', 'id')
  end

  # 4. Create the reservation.
  reservation_body = JSON.generate(
    data: {
      type: 'reservations',
      attributes: {
        'start-time' => start_ts,
        'end-time' => end_ts,
        'check-in-time' => nil,
        'check-out-time' => nil,
        'canceled-at' => nil,
        'user-email' => nil,
        'is-partial-day' => false,
      },
      relationships: {
        desk: { data: { type: 'desks', id: options[:desk_id] } },
        location: { data: { type: 'locations', id: options[:location_id] } },
        invite: { data: { type: 'invites', id: invite_id } },
        user: { data: { type: 'users', id: options[:user_id] } },
      }
    }
  )
  reservation_resp = request(
    RESERVATIONS_URL,
    method: :post,
    headers: {
      'content-type' => 'application/vnd.api+json',
      'x-csrf-token' => csrf_token,
      'x-envoy-context' => envoy_context,
    },
    body: reservation_body,
    cookie: cookie
  )
  return ['booked', reservation_resp] if reservation_resp.is_a?(Net::HTTPSuccess)

  body = reservation_resp.body.to_s
  # 422 + code 1002 = desk unavailable, almost always your own prior booking.
  if reservation_resp.code == '422' && body.match?(/"code":\s*1002/)
    return ['UNAVAILABLE - desk already taken (likely already yours)', reservation_resp]
  end

  ["FAILED booking desk (#{reservation_resp.code}): #{body[0, 150]}", reservation_resp]
end

targets = []
d = start_date
while d <= end_date
  targets << d if options[:include_weekends] || !d.saturday? && !d.sunday?
  d += 1
end

if options[:dry_run]
  puts "Would book #{targets.size} day(s) from #{start_date} to #{end_date}" \
       "#{options[:include_weekends] ? '' : ' (weekdays only)'}:"
  targets.each { |t| puts "  #{t}" }
  exit 0
end

results = []
consecutive_failures = 0
stop_reason = nil

targets.each do |date|
  label = date.strftime('%a %b %-d %Y')

  status, = book_day(date, options, envoy_context, cookie, csrf_token, desk_reservations_url)

  attempt = 0
  while status.start_with?('FAILED') && (status.include?('(401)') || status.include?('(403)')) && attempt < options[:auth_retries]
    attempt += 1
    puts "  #{label}: auth failure, waiting #{options[:auth_retry_wait]}s then retry #{attempt}/#{options[:auth_retries]}..."
    sleep options[:auth_retry_wait]
    status, = book_day(date, options, envoy_context, cookie, csrf_token, desk_reservations_url)
  end

  results << { date: label, status: status }
  puts "  #{label}: #{status}"

  if status.include?('(401)') || status.include?('(403)')
    stop_reason = 'Session cookie/CSRF token lapsed and did not recover after retries. ' \
                  'Refresh ENVOY_COOKIE / ENVOY_CSRF_TOKEN from a logged-in browser tab ' \
                  '(see README.md) and re-run — already-booked days are skipped, so it ' \
                  'resumes where it left off.'
    break
  end

  is_failure = status.start_with?('FAILED') || status.start_with?('ERROR')
  consecutive_failures = is_failure ? consecutive_failures + 1 : 0
  if consecutive_failures >= options[:stop_after_consecutive_failures]
    stop_reason = "#{consecutive_failures} non-auth failures in a row — possibly hit " \
                  'Envoy\'s advance-booking window limit. Stopping. Re-run later as ' \
                  'those dates come closer.'
    break
  end

  sleep options[:delay] if options[:delay] && !date.equal?(targets.last)
end

booked = results.count { |r| r[:status] == 'booked' }
skipped = results.count { |r| r[:status] == 'already booked - skipped' }
unavailable = results.count { |r| r[:status].start_with?('UNAVAILABLE') }
failed = results.count { |r| r[:status].start_with?('FAILED') || r[:status].start_with?('ERROR') }

puts
puts "Summary: #{booked} booked, #{skipped} already-booked/skipped, " \
     "#{unavailable} desk-unavailable, #{failed} failed."

if unavailable.positive?
  warn "#{unavailable} day(s) show the desk unavailable. If those are days you " \
       'already booked, that\'s expected. If not, someone else may have taken ' \
       'the desk on those dates — worth checking your schedule.'
end

warn "Stopped early: #{stop_reason}" if stop_reason
