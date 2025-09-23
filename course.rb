require 'nokogiri'
require 'json'
require 'date'
require_relative 'parser'

class Course
  attr_accessor :linkedin, :populated
  # If completed, minutes_remaining is nil.
  # If in progress, completion_date is nil.
  # TODO: learning_path || nil
  attr_accessor :url, :title, :minutes_remaining, :completion_date, :authors, :difficulty, :updated_date, :ratings, :ratings_count, :certified, :credits

  def initialize(linkedin = nil)
    @linkedin = linkedin
    @credits = {}
    @populated = false
  end

  def navigate()
    return unless @linkedin
    return if @url.nil? || @title.nil?

    refresh = @linkedin.driver.current_url == @url
    if refresh
      @linkedin.driver.navigate.refresh
    else
      @linkedin.driver.navigate.to(@url)
    end

    @linkedin.wait.until {
      @linkedin.driver.find_elements(css: '.classroom-workspace-overview__header').any? ||
      @linkedin.driver.find_elements(css: '.error-body__content').any?
    }

    return if refresh

    backoff = 0
    until @linkedin.driver.find_elements(css: '.error-body__content').empty?
      backoff += 1
      warn "Client may be rate limited!"
      @linkedin.humanized_sleep(20, 30 + (backoff * 10))
      navigate()
    end

    until @linkedin.driver.find_elements(css: '.classroom-workspace-overview__details-meta li:nth-child(2)').any?
      @linkedin.humanized_sleep(1, 2)
      navigate()
    end
  end

  def populate
    return unless @linkedin
    return if @url.nil? || @title.nil?

    # Technically not yet populated, but this is easy.
    @populated = true
    if @linkedin.is_cached?(@url)
      return from_hash(@linkedin.cache[@url])
    end

    # Navigate to course if not already there.
    navigate()
    @linkedin.humanized_sleep(1, 2)
    @linkedin.scroll_dynamic()
    @linkedin.humanized_sleep(1, 2)

    html = Nokogiri::HTML(@linkedin.driver.page_source)

    # We cannot scrape completion date or minutes remaining from the HTML here.
    @authors = Parser.get_authors(html)
    @minutes = Parser.get_minutes(html)
    @difficulty = Parser.get_difficulty(html)
    @updated_date = Parser.get_updated_date(html)
    @ratings = Parser.get_ratings(html)
    @ratings_count = Parser.get_ratings_count(html)
    @certified = Parser.has_certifying_organizations?(html)
    @credits = {}

    if @certified
      begin
        creds = Parser.get_course_credits(html)
        @credits = creds unless creds.empty?
      rescue => e
        puts "Error parsing credits for #{@url}: #{e.class}: #{e.message}"
      end
    end

    @linkedin.cache[@url] = to_hash
    @linkedin.save_cache_atomic()
  end

  def to_hash
    populate() unless @populated
    {
      "type" => 'course',
      "url" => @url,
      "title" => @title,
      "authors" => @authors,
      "minutes" => @minutes,
      "minutes_remaining" => @minutes_remaining,
      "difficulty" => @difficulty,
      "updated_date" => @updated_date,
      "completion_date" => @completion_date,
      "ratings" => @ratings,
      "ratings_count" => @ratings_count,
      "certified" => @certified,
      "credits" => @credits
    }
  end

  def from_hash(hash)
    @url = hash["url"]
    @title = hash["title"]
    @authors = hash["authors"]
    @minutes = hash["minutes"]
    @minutes_remaining = hash["minutes_remaining"]
    @difficulty = hash["difficulty"]
    @updated_date = hash["updated_date"]
    @updated_date = hash["completion_date"]
    @ratings = hash["ratings"]
    @ratings_count = hash["ratings_count"]
    @certified = hash["certified"]
    @credits = hash["credits"] || {}
    self
  end
end
