require 'selenium-webdriver'
require 'nokogiri'
require 'json'
require 'optparse'
require 'time'
require_relative 'parse'
require 'date'

class LinkedIn
  attr_accessor :cache, :cache_dir
  attr_accessor :driver, :wait
  # TODO: Profiling?
  #attr_accessor :profile

  # TODO: I don't want to have this. Disorganized.
  module Parser
    def extract_items(html)
      results = []

      html.css('.lls-card-headline').each do |span|
        title = span.text.to_s.strip
        next if title.empty?
        anchor = span.ancestors('a').find do |a|
          cls = (a['class'] || '')
          cls.split.include?('ember-view') && cls.split.include?('entity-link')
        end
        anchor ||= span.ancestors('a').first
        next unless anchor && anchor['href']
        href = anchor['href'].strip
        url = (URI.join('https://www.linkedin.com', href).to_s rescue href).split("?")[0]
        results << { title: title, url: url }
      end

      results
    end

    def has_certifying_organizations?(html)
      html.css('div.classroom-credential-details').any?
    end

    def get_course_credits(html)
      creds = {}
      html.css('div.classroom-credential-details__description-content').each do |div|
        # Find all strong nodes inside the div.
        div.css('strong').each do |strong|
            str = strong.text.to_s.strip
            type = case str
              when /Continuing Professional Education Credit/
                  "CPE" # NASBA
              when /Continuing Education Units/
                  "CEU" # CompTIA
              when /PDUs\/ContactHours/
                  "PDU" # PMI
              when /Professional Development Credits/
                  "PDC" # SHRM
              when /Recertification Credits/
                  "HRCI" # HRCI
              when /Continuing Development Units/
                  "CDU" # IIBA
              else
                  nil
            end

            next unless type

            count = strong.next.text.to_s.strip.to_f
            creds[type] = count
        end
      end
      creds
    end

    def get_authors(html)
      html.at_css(".classroom-authors-summary__names").text.to_s.strip.split(' and ') rescue 
      html.at_css(".instructor__name").text.to_s.strip.split("\n")[0] rescue nil;
    end

    def get_ratings(html)
      html.css("span._bodyText_1e5nen._default_1i6ulk._sizeMedium_1e5nen")[0].text.to_s.strip.to_f
    end

    def get_ratings_count(html)
      # Rating count is contained inside of parenthesis.
      html.css("span._bodyText_1e5nen._default_1i6ulk._sizeMedium_1e5nen")[1].text.to_s.strip[1..-2].to_i
    end

    def get_minutes(html)
      list = html.at_css(".classroom-workspace-overview__details-meta")
      dur = list.xpath('./li')[0].text.to_s.strip
      hours = dur[/(\d+)h/, 1].to_i
      mins = dur[/(\d+)m/, 1].to_i
      hours * 60 + mins
    end

    def get_difficulty(html)
      list = html.at_css(".classroom-workspace-overview__details-meta")
      list.xpath('./li')[1].text.to_s.strip
    end

    def get_updated_date(html)
      list = html.at_css(".classroom-workspace-overview__details-meta")
      date = list.xpath('./li')[2].text.to_s.strip
      Date.strptime(date.split(' ')[1].strip, "%m/%d/%Y")
    end

    def get_provider(html)
      if html.css(".path-body-v2__certification-provider-name").any?
        html.at_css(".path-body-v2__certification-provider-name").text.to_s.strip;
      elsif html.css(".path-body-v2__header-provider").any?
        html.at_css(".path-body-v2__header-provider p").text.to_s.strip;
      end
    end
  end

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

  def learning_completed_show_more()
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

  def learning_completed()
    @driver.navigate.to("https://www.linkedin.com/learning/me/my-library/completed")
    @wait.until {
      @driver.find_elements(css: '.lls-card-headline').any?
    }

    items = []
    loop do
      scroll_dynamic()
      @wait.until {
        @driver.find_elements(css: '.lls-card-headline').length > items.size
      }

      state = learning_completed_show_more()
      sleep 0.5 unless state

      html = Nokogiri::HTML(@driver.page_source)
      items |= LinkedIn::Parser.extract_items(html)
      break unless state
    end
    items
  end

  # TODO: Technically in fringe cases this can cause a stack overflow.
  #       I'm not particularly concerned about it but it should be addressed.
  def learning_course_navigate(url)
    refresh = @driver.current_url == url
    if refresh
      @driver.navigate.refresh
    else
      @driver.navigate.to(url)
    end

    @wait.until {
      @driver.find_elements(css: '.classroom-workspace-overview__header').any? ||
      @driver.find_elements(css: '.error-body__content').any?
    }

    return if refresh

    backoff = 0
    until @driver.find_elements(css: '.error-body__content').empty?
      backoff += 1
      warn "Client may be rate limited!"
      humanized_sleep(20, 30 + (backoff * 10))
      learning_course_navigate(url);
    end

    until @driver.find_elements(css: '.classroom-workspace-overview__details-meta').any? { |e| e.displayed? }
      humanized_sleep(1, 2)
      learning_course_navigate(url);
    end
  end

  def learning_course_json(url, title)
    if is_cached?(url)
      return @cache[url]
    end

    learning_course_navigate(url)
    humanized_sleep(1, 2)
    scroll_dynamic()
    humanized_sleep(1, 2)
    html = Nokogiri::HTML(@driver.page_source)

    rec = {
      "type" => 'course',
      "url" => url,
      "title" => title,
      "authors" => LinkedIn::Parser.get_authors(html),
      "minutes" => LinkedIn::Parser.get_minutes(html),
      "difficulty" => LinkedIn::Parser.get_difficulty(html),
      "updated_date" => LinkedIn::Parser.get_updated_date(html),
      "ratings" => LinkedIn::Parser.get_ratings(html),
      "ratings_count" => LinkedIn::Parser.get_ratings_count(html),
      "certified" => LinkedIn::Parser.has_certifying_organizations?(html),
      "credits" => {},
    }
    if rec["certified"]
      begin
        creds = LinkedIn::Parser.get_course_credits(html)

        unless creds.empty?
          rec["credits"] = creds rescue {}
        end
      rescue => e
        puts "Error parsing credits for #{url}: #{e.class}: #{e.message}"
      end
    end

    @cache[url] = rec
    save_cache_atomic()
    rec
  end

  def learning_path_navigate(url)
    refresh = @driver.current_url == url
    if refresh
      @driver.navigate.refresh
    else
      @driver.navigate.to(url)
    end

    wait.until {
        @driver.find_elements(css: '.lls-card-headline').any? ||
        @driver.find_elements(css: '.error-body__content').any?
    }

    return if refresh

    backoff = 0
    until @driver.find_elements(css: '.error-body__content').empty?
      backoff += 1
      warn "Client may be rate limited!"
      humanized_sleep(20, 30 + (backoff * 10))
      learning_path_navigate(url);
    end

    until @driver.find_elements(css: '.path-body-v2__certification-provider-name').any? { |e| e.displayed? } ||
        @driver.find_elements(css: '.path-body-v2__header-provider').any? { |e| e.displayed? }
      humanized_sleep(1, 2)
      learning_path_navigate(url);
    end
  end

  def learning_path_json(url, title)
    if is_cached?(url)
      return @cache[url]
    end

    learning_path_navigate(url)
    humanized_sleep(1, 2)
    html = Nokogiri::HTML(@driver.page_source)

    items = LinkedIn::Parser.extract_items(html)
    rec = {
      "type" => 'path',
      "url" => url,
      "title" => title,
      "provider" => LinkedIn::Parser.get_provider(html),
      "courses" => [],
      "minutes" => 0,
      "difficulty" => nil,
      "updated_date" => nil,
      "ratings" => 0,
      "ratings_count" => 0,
      "certified" => false,
      "credits" => {},
    }

    items.each do |_c|
      c = @cache[_c[:url]]
      c = learning_course_json(_c[:url], _c[:title]) if c.nil?
      
      # TODO: Maybe store only the URL and not the entire course.
      rec["courses"] << c["url"]
      rec["updated_date"] = [rec["updated_date"], Date.parse(c["updated_date"].to_s)].compact.max
      rec["minutes"] += c["minutes"]
      rec["ratings"] += c["ratings"]
      rec["ratings_count"] += c["ratings_count"]
      rec["certified"] |= c["certified"]

      c["credits"].each do |type, count|
        unless rec["credits"][type].nil?
          rec["credits"][type] += count;
        else
          rec["credits"][type] = count;
        end
      end

      rec["difficulty"] = case c["difficulty"]
        when /Advanced/
          "Advanced"
        when /Intermediate/
          "Intermediate"
        when /Beginner/
          "Beginner"
        when /General/
          "General"
        else
          rec["difficulty"]
      end
    end
    rec["ratings"] = (rec["ratings"] / (rec["courses"].size.to_f || 1.0)).round(1)

    @cache[url] = rec
    save_cache_atomic()
    rec
  end

  def learning_json(url, title)
    if url.start_with?("https://www.linkedin.com/learning/paths")
      learning_path_json(url, title)
    elsif url.start_with?("https://www.linkedin.com/learning")
      learning_course_json(url, title)
    else
      raise "URLs must be absolute, beginning with https://www.linkedin.com/learning. Provided: #{url} for #{title}.";
    end
  end
end