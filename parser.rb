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