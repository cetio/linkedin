require 'selenium-webdriver'
require 'nokogiri'
require 'json'
require 'optparse'
require 'time'
require 'date'
require_relative 'parser'
require_relative 'course'
require_relative 'path'

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
    # We do this because this only applies to learning history.
    btn = @driver.find_element(:xpath, "//button[@aria-label='Show more learning history']") rescue nil

    @wait.until {
      btn.displayed? && btn.enabled? && btn.attribute('aria-disabled') != 'true'
    } rescue return false

    @driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", btn)
    sleep 0.05

    begin
      @driver.action.move_to(btn).perform
      sleep 0.05
      btn.click()
      return true
    rescue
      false
    end

    begin
      @driver.execute_script("arguments[0].click();", btn)
      return true
    rescue
      false
    end
  end

  def learning_count(variety)
    raise "Unsupported variety, only 'all', 'completed', 'in-progress', and 'saved' are supported!" unless
      variety == 'all' ||
      variety == 'completed' ||
      variety == 'in-progress' ||
      variety == 'saved'

    if variety == 'all'
      return learning_count('completed') + learning_count('in-progress') + learning_count('saved')
    end

    @driver.navigate.to("https://www.linkedin.com/learning/me/my-library/#{variety}")
    # TODO: Rate limit handling.
    @wait.until {
      @driver.find_element(xpath: "//*[@id='hue-tabs-ember62-tab-me.my-library.#{variety}']")
    }

    begin
      span = @driver.find_element(xpath: "//*[@id='hue-tabs-ember62-tab-me.my-library.#{variety}']").find_element(tag_name: 'span')
      span.text.to_s.strip.match(/(\d+)/)[0].to_i
    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      # TODO: This can cause a stack overflow.
      learning_count(variety)
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

    items = []
    # This will also navigate us to the page.
    count = learning_count(variety)
    @wait.until {
      @driver.find_elements(css: '.lls-card-headline').any?
    }

    loop do
      scroll_dynamic()
      learning_show_more() if variety == 'completed'

      html = Nokogiri::HTML(@driver.page_source)
      Parser.extract(html, self).each() do |item|
        # This is slow but scraping is slower.
        next if items.any? { |i| i.url == item.url }
        items << item unless item.nil?
        count -= 1
      end

      break if count <= 0
    end

    items
  end
end
