#!/usr/bin/env ruby
require 'nokogiri'
require 'json'
require 'date'
require_relative 'course'
require_relative 'path'

module Parser
  def self.extract(html, instance = nil)
    results = []

    footer = html.css('.lls-card-detail-card-body__footer')
    html.css('.lls-card-headline').each_with_index do |span, index|
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

      footer = html.css('.lls-card-detail-card-body__footer')[index]
      metadata = footer.at_css('.lls-card-meta-list')
      minutes_remaining = nil
      completion_date = nil

      unless metadata.nil? || metadata.at_css('.lls-card-duration').nil?
        dur = metadata.at_css('.lls-card-duration').text.to_s.strip
        hours = dur[/(\d+)h/, 1].to_i
        mins = dur[/(\d+)m/, 1].to_i
        minutes_remaining = hours * 60 + mins
      end

      metadata = footer if metadata.nil? && !footer.at_css('.lls-card-completion-state--completed').nil?
      unless metadata.nil? || metadata.at_css('.lls-card-completion-state--completed').nil?
        date = metadata.at_css('.lls-card-completion-state--completed').text.to_s.strip
        completion_date = Date.strptime(date.split(' ')[1].strip, "%m/%d/%Y")
      end

      if url.start_with?("https://www.linkedin.com/learning/paths")
        path = Path.new(instance)
        path.url = url
        path.title = title
        results << path
      elsif url.start_with?("https://www.linkedin.com/learning")
        course = Course.new(instance)
        course.url = url
        course.title = title
        course.minutes_remaining = minutes_remaining
        course.completion_date = completion_date
        results << course
      elsif url.start_with?("https://www.linkedin.com/learning/videos")
        # Videos are currently not supported.
        results << nil
      end
    end

    results
  end

  def self.extract_basic(html)
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
      next if url.start_with?("https://www.linkedin.com/learning/videos")

      results << { title: title, url: url }
    end

    results
  end

  def self.has_certifying_organizations?(html)
    html.css('div.classroom-credential-details').any?
  end

  def self.get_course_credits(html)
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

  def self.get_authors(html)
    cards = html.css('.course-overview-author-cards__card-title')
    return cards.map { |c| c.text.to_s.strip }.reject(&:empty?).join(' and ') if cards.any?
    html.at_css(".classroom-authors-summary__names").text.to_s.strip.split(' and ') rescue
    html.at_css(".instructor__name").text.to_s.strip.split("\n")[0] rescue
    html.at_css(".classroom-content-provider__metadata").at_css("._bodyText_1e5nen").text.to_s.strip.sub(/^Author: /, '') rescue nil
  end

  def self.get_ratings(html)
    # Sometimes items will not have ratings for some reason.
    html.at_css('.ratings-meta__average-rating').text.to_s.strip[/[\d.]+/].to_f rescue 0
  end

  def self.get_ratings_count(html)
    # e.g. "1,545 ratings"
    html.at_css('.ratings-meta__ratings-count').text.to_s.strip.gsub(',', '')[/\d+/].to_i rescue 0
  end

  # Meta list ordering is not stable; identify each field by content pattern.
  DIFFICULTY_LEVELS = %w[Beginner Intermediate Advanced General].freeze

  def self.meta_items(html)
    list = html.at_css(".course-overview-header__meta-list")
    return [] unless list
    list.xpath('./li').map { |li| li.text.to_s.strip }
  end

  def self.get_minutes(html)
    dur = meta_items(html).find { |t| t =~ /\d+\s*[hms]/ }
    return 0 unless dur
    hours = dur[/(\d+)\s*h/, 1].to_i
    mins = dur[/(\d+)\s*m/, 1].to_i
    hours * 60 + mins
  end

  def self.get_difficulty(html)
    items = meta_items(html)
    found = items.find { |t| DIFFICULTY_LEVELS.include?(t) }
    found || "General"
  end

  def self.get_updated_date(html)
    raw = meta_items(html).find { |t| t =~ /^(Updated|Released):/i }
    return nil unless raw
    date_str = raw.sub(/^[^:]+:\s*/, '').strip
    Date.strptime(date_str, "%B %d, %Y") rescue nil
  end

  def self.get_provider(html)
    if html.css(".path-body-v2__certification-provider-name").any?
      html.at_css(".path-body-v2__certification-provider-name").text.to_s.strip;
    elsif html.css(".path-body-v2__header-provider").any?
      html.at_css(".path-body-v2__header-provider p").text.to_s.strip;
    end
  end
end
