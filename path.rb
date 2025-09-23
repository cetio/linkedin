require 'nokogiri'
require 'json'
require 'date'
require_relative 'parser'
require_relative 'course'

class Path
  attr_accessor :linkedin, :populated
  # If completed, minutes_remaining is nil.
  # If in progress, completion_date is nil.
  attr_accessor :url, :title, :minutes_remaining, :completion_date, :provider, :courses, :difficulty, :updated_date, :ratings, :ratings_count, :certified, :credits

  def initialize(linkedin = nil)
    @linkedin = linkedin
    @courses = []
    @credits = {}
    @minutes = 0
    @minutes_remaining = 0
    @ratings = 0
    @ratings_count = 0
    @certified = false
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
      @linkedin.driver.find_elements(css: '.lls-card-headline').any? ||
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

    until @linkedin.driver.find_elements(css: '.path-body-v2__certification-provider-name').any? { |e| e.displayed? } ||
        @linkedin.driver.find_elements(css: '.path-body-v2__header-provider').any? { |e| e.displayed? }
      @linkedin.humanized_sleep(1, 2)
      navigate()
    end
  end

  # TODO: This is AI ported code and, while it works fine, needs to be reviewed and rewritten.
  def populate
    return unless @linkedin
    return if @url.nil? || @title.nil?

    # Technically not yet populated, but this is easy.
    @populated = true
    if @linkedin.is_cached?(@url)
      return from_hash(@linkedin.cache[@url])
    end

    # Navigate to path if not already there
    navigate()
    @linkedin.humanized_sleep(1, 2)

    # Get fresh page source
    html = Nokogiri::HTML(@linkedin.driver.page_source)

    # Populate from HTML
    @provider = Parser.get_provider(html)

    # Extract course items from the path (basic data only)
    # TODO: Not this.
    items = Parser.extract_basic(html)

    # Process each course in the path
    items.each do |course_item|
      course_url = course_item[:url]
      course_title = course_item[:title]

      # Get course data (from cache or by parsing)
      course_data = @linkedin.cache[course_url]
      if course_data.nil?
        course = Course.new(@linkedin)
        course.url = course_url
        course.title = course_title
        course.populate  # Will navigate and populate
        course_data = course.to_hash
      end

      # Add course URL to our courses list
      @courses << course_data["url"]

      # Aggregate data from courses
      aggregate_course_data(course_data)
    end

    @ratings = (@ratings / (@courses.size.to_f || 1.0)).round(1)

    @linkedin.cache[@url] = to_hash
    @linkedin.save_cache_atomic()
  end

  def aggregate_course_data(course_data)
    # Update the most recent updated_date
    # TODO: completion_date
    course_updated_date = Date.parse(course_data["updated_date"].to_s) if course_data["updated_date"]
    @updated_date = [@updated_date, course_updated_date].compact.max

    # Sum up minutes
    @minutes += course_data["minutes"] || 0
    @minutes_remaining += course_data["minutes"] || 0

    # Sum up ratings and ratings_count
    @ratings += course_data["ratings"] || 0
    @ratings_count += course_data["ratings_count"] || 0

    # Set certified if any course is certified
    @certified |= course_data["certified"] || false

    # Aggregate credits
    if course_data["credits"]
      course_data["credits"].each do |type, count|
        if @credits[type]
          @credits[type] += count
        else
          @credits[type] = count
        end
      end
    end

    # Set difficulty based on course difficulty (Advanced > Intermediate > Beginner > General)
    course_difficulty = course_data["difficulty"]
    @difficulty = determine_highest_difficulty(@difficulty, course_difficulty)
  end

  def determine_highest_difficulty(current_difficulty, new_difficulty)
    difficulty_levels = {
      "Advanced" => 4,
      "Intermediate" => 3,
      "Beginner" => 2,
      "General" => 1
    }

    current_level = difficulty_levels[current_difficulty] || 0
    new_level = difficulty_levels[new_difficulty] || 0

    if new_level > current_level
      new_difficulty
    else
      current_difficulty
    end
  end

  def to_hash
    populate() unless @populated
    {
      "type" => 'path',
      "url" => @url,
      "title" => @title,
      "provider" => @provider,
      "courses" => @courses,
      "minutes" => @minutes_remaining,
      "difficulty" => @difficulty,
      "updated_date" => @updated_date,
      "ratings" => @ratings,
      "ratings_count" => @ratings_count,
      "certified" => @certified,
      "credits" => @credits
    }
  end

  def from_hash(hash)
    @url = hash["url"]
    @title = hash["title"]
    @provider = hash["provider"]
    @courses = hash["courses"] || []
    @minutes_remaining = hash["minutes"]
    @difficulty = hash["difficulty"]
    @updated_date = hash["updated_date"]
    @ratings = hash["ratings"]
    @ratings_count = hash["ratings_count"]
    @certified = hash["certified"]
    @credits = hash["credits"] || {}
    self
  end
end
