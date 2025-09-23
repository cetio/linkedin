require 'selenium-webdriver'
require 'nokogiri'
require 'json'
require 'optparse'
require 'time'
require_relative 'parser'
require_relative 'course'
require_relative 'path'
require 'date'

class LinkedIn
  attr_accessor :cache, :cache_dir
  attr_accessor :driver, :wait
  # TODO: Profiling?
  #attr_accessor :profile

  def load_cache()
    return {} unless !@cache_dir.nil? && File.exist?(@cache_dir)

    begin
      data = File.read(@cache_dir)
      parsed = JSON.parse(data)
      parsed.each_with_object({}) { |(k,v), h| h[k.to_s] = v }
    rescue => e
      warn "Failed to read cache #{@cache_dir}: #{e.class}: #{e.message}"
      {}
    end
  end

  def save_cache_atomic()
    begin
      tmp = "#{@cache_dir}.tmp"
      File.open(tmp, "w") { |f|
        f.write(JSON.pretty_generate(@cache))
      }
      File.rename(tmp, @cache_dir)
      true
    rescue => e
      warn "Failed to save cache #{@cache_dir}: #{e.class}: #{e.message}"
      false
    end
  end

  def is_cached?(url)
    @cache[url]
  end

  def initialize(driver, email, password, cache_dir)
    @driver = driver
    @driver.navigate.to("https://www.linkedin.com/login")
    @wait = Selenium::WebDriver::Wait.new(timeout: 12)
    @cache_dir = cache_dir
    @cache = load_cache()

    unless email.nil? || password.nil?
      begin
        humanized_sleep(0.3, 1)
        @driver.find_element(:id, 'username').send_keys(email)
        humanized_sleep(0.3, 1)
        @driver.find_element(:id, 'password').send_keys(password)
        @driver.find_element(:id, 'password').submit
      rescue
      end
    end

    until @driver.current_url == "https://www.linkedin.com/feed/"
      sleep 0.5
    end
  end

  def scroll_dynamic(
    min_poll: 0.03,
    max_poll: 0.5,
    stable_required: 3,
    max_seconds: 12
  )
    get_height_js = "return Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);"
    start_time = Time.now
    stable_count = 0
    poll = min_poll
    height = @driver.execute_script(get_height_js)

    loop do
      # Incremental scroll.
      @driver.execute_script("window.scrollBy(0, Math.max(window.innerHeight * 0.9, 200));")

      start_poll = Time.now
      new_height = height
      loop do
        new_height = @driver.execute_script(get_height_js)
        break if new_height > height
        break if (Time.now - start_poll) >= poll
        sleep 0.01
      end

      if new_height > height
        height = new_height
        stable_count = 0
        poll = min_poll
      else
        stable_count += 1
        poll = [poll * 2, max_poll].min
      end

      break if stable_count >= stable_required
      break if (Time.now - start_time) >= max_seconds
    end

    # Ensure we are actually at the bottom.
    @driver.execute_script("window.scrollTo(0, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));")
  end

  def humanized_sleep(min, max)
    sleep(rand(min..max) + rand * 0.3)
  end

  def learning_show_more()
    max_attempts = 5
    attempts = 0

    begin
      attempts += 1

      btn = nil
      begin
        btn = @driver.find_element(:xpath, "//button[@aria-label='Show more learning history']")
        return false if btn.nil?
      rescue Selenium::WebDriver::Error::NoSuchElementError
        return false
      end

      begin
        @wait.until {
          btn.displayed? && btn.enabled? && btn.attribute('aria-disabled') != 'true'
        }
      rescue Selenium::WebDriver::Error::TimeoutError
        return false
      end

      @driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", btn)
      sleep 0.05

      begin
        @driver.action.move_to(btn).perform
        sleep 0.05
        btn.click
        return true
      rescue Selenium::WebDriver::Error::ElementClickInterceptedError, Selenium::WebDriver::Error::StaleElementReferenceError
      end

      begin
        @driver.execute_script("arguments[0].click();", btn)
        return true
      rescue => js_err
        # Give a tiny pause and retry if attempts remain.
        sleep 0.2
        if attempts < max_attempts
          retry
        else
          warn "Failed to click show more: #{js_err.class}: #{js_err.message}"
          return false
        end
      end

    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      if attempts < max_attempts
        sleep 0.1
        retry
      end
      warn "Failed to click show more: element went stale repeatedly"
      return false
    rescue => e
      warn "Failed to click show more: #{e.class}: #{e.message}"
      return false
    end
  end

  def learning_collect(variety)
    raise "Unsupported variety, only 'all', 'completed', 'in-progress', and 'saved' are supported!" unless
      variety == 'all' ||
      variety == 'completed' ||
      variety == 'in-progress' ||
      variety == 'saved'

    if variety == 'all'
      return learning_collect('completed') + learning_collect('in-progress') + learning_collect('saved')
    end

    # TODO: This needs to make sure the page loads before waiting and it fails on saved library items.
    # TODO: This needs to be able to handle errors/rate limiting on the page.
    # TODO: This may not be collecting all items correctly and the logic is quite poor.
    @driver.navigate.to("https://www.linkedin.com/learning/me/my-library/#{variety}")
    @wait.until {
      @driver.find_elements(css: '.lls-card-headline').any?
    }

    items = []
    loop do
      scroll_dynamic()
      @wait.until {
        @driver.find_elements(css: '.lls-card-headline').length > items.size
      }

      state = learning_show_more()
      sleep 0.5 unless state

      html = Nokogiri::HTML(@driver.page_source)
      new_items = Parser.extract(html, self)

      # Add new items, avoiding duplicates
      new_items.each do |item|
        next if items.any? { |existing| existing.url == item.url }
        items << item
      end

      break unless state
    end

    items
  end

  def learning_in_progress()
    @driver.navigate.to("https://www.linkedin.com/learning/me/my-library/in-progress")
    @wait.until {
      @driver.find_elements(css: '.lls-card-headline').any?
    }

    items = []
    loop do
      scroll_dynamic()
      @wait.until {
        @driver.find_elements(css: '.lls-card-headline').length > items.size
      }

      state = learning_show_more()
      sleep 0.5 unless state

      html = Nokogiri::HTML(@driver.page_source)
      new_items = Parser.extract(html, self)

      # Add new items, avoiding duplicates
      new_items.each do |item|
        next if items.any? { |existing| existing.url == item.url }
        items << item
      end

      break unless state
    end
    items
  end
end
