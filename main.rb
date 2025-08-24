#!/usr/bin/env ruby
require 'selenium-webdriver'
require 'json'
require 'optparse'
require 'time'
require_relative 'parse'
require_relative 'linkedin'
require 'date'

options = {
  headless: true,
  datadir: nil,
  email: nil,
  password: nil,
  output: "report.json",
  cache: "cache.json"
}

OptionParser.new do |opts|
  opts.banner = "Usage: main.rb [options]"
  opts.on("--headless [BOOLEAN]") { |v| options[:headless] = v != "false" }
  opts.on("--datadir FILE") { |v| options[:datadir] = v }
  opts.on("--email EMAIL") { |v| options[:email] = v }
  opts.on("--password PASS") { |v| options[:password] = v }
  opts.on("--output FILE") { |v| options[:output] = v }
  opts.on("--cache FILE", "Course cache file (JSON). Default: course_cache.json") { |v| options[:cache] = v }
  opts.on_tail("-h", "--help") { puts opts; exit }
end.parse!

def start_driver(headless, datadir)
  puts "Starting Chrome driver (headless: #{headless})"
  opts = Selenium::WebDriver::Chrome::Options.new
  [
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-extensions",
    "--window-size=1366,768",
    "--user-data-dir=/home/cet/.config/thorium/",
    "--profile-directory=Default"
  ].each { |a| opts.add_argument(a) }

  if headless
    begin
      opts.add_argument("--headless=new")
    rescue
      opts.add_argument("--headless")
    end
  end
  Selenium::WebDriver.for(:chrome, options: opts)
end

driver = nil
begin
  driver = start_driver(options[:headless], options[:datadir])
  linkedin = LinkedIn.new(
    driver, 
    options[:email], options[:password], 
    options[:cache]
  )

  items = linkedin.learning_completed()
  cached = items.sum { |u| linkedin.is_cached?(u[:url]) ? 1 : 0 }
  puts "Collected #{items.size} items, #{cached} cached."
  eta_secs = (items.size - cached) * 4 + (((items.size - cached) / 10) * 30)
  eta_mins = (eta_secs / 60.0).truncate
  eta_secs -= eta_mins * 60
  puts "ETA: #{eta_mins}m #{eta_secs}s"

  json = items.map { |u| 
    puts "#{items.index(u)}/#{items.size}: #{u[:title]}"
    linkedin.learning_json(u[:url], u[:title]) 
  }

  out = {
    date: Time.now.utc.iso8601,
    items_count: items.size,
    items: json
  }

  File.open(options[:output], 'w') { |f| f.write(JSON.pretty_generate(out)) }
  puts "Saved #{items.size} items to #{options[:output]}"
  puts JSON.pretty_generate(out)

rescue => e
  warn "Error: #{e.class}: #{e.message}"
  warn e.backtrace.take(20).join("\n")
ensure
  if driver
    puts "Closing browser..."
    driver.quit
  end
  puts "Done."
end
