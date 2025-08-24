# LinkedIn Ruby

> [!WARNING]
> This tool is for personal use only! Scraping someone else's account or distributing scraped data is a violation of LinkedIn's terms of use and may be illegal in some jurisdictions. Use it responsibly, throttle your requests, and respect rate limits.

> [!NOTE]
> This project was written in 12 hours with no prior experience in Ruby or Selenium. I try my best, but any bugs or problems should be reported with an issue.

LinkedIn Ruby (not the website) is a CLI tool and pseudo-library that fetches your LinkedIn Learning completed history and extracts course and learning path metadata into a simple cacheable JSON aggregate.

It's designed to be human-friendly, tolerant of LinkedIn's rate limits, and to avoid hammering the site unnecessarily.

## Usage

Chromium Default profile:

```bash
ruby main.rb --datadir /home/john/.config/thorium/
```

> [!TIP]
> Using your Chrome Default profile is the easiest (and recommended) way to run this. Supplying email/password on the command line is supported but not recommended. It's less secure and more likely to trigger additional checks from LinkedIn.

Login credentials:


```bash
ruby main.rb --email john@example.com --password Pa55W0rD
```

## Output

For courses, the following data is aggregated:

```json
{
  "type": "course",
  "url": "https://www.linkedin.com/learning/customer-service-problem-solving-and-troubleshooting-16015212",
  "title": "Customer Service: Problem-Solving and Troubleshooting",
  "authors": "Noah Fleming",
  "minutes": 35,
  "difficulty": "Beginner",
  "updated_date": "2022-10-31",
  "ratings": 4.8,
  "ratings_count": 7,
  "certified": true,
  "credits": {
    "CPE": 1.0,
    "PDU": 0.5
  }
}
```

For learning paths, the following data is aggregated:

```json
{
  "type": "path",
  "url": "https://www.linkedin.com/learning/paths/zendesk-customer-service-professional-certificate",
  "title": "Zendesk Customer Service Professional Certificate",
  "provider": "Zendesk",
  "courses": [
    "https://www.linkedin.com/learning/customer-service-foundations-21620021",
    "https://www.linkedin.com/learning/customer-service-problem-solving-and-troubleshooting-16015212",
    "https://www.linkedin.com/learning/building-rapport-with-customers-2022",
    "https://www.linkedin.com/learning/customer-service-handling-abusive-customers-25071433",
    "https://www.linkedin.com/learning/creating-positive-conversations-with-challenging-customers-2022",
    "https://www.linkedin.com/learning/serving-customers-using-social-media-23748575"
  ],
  "minutes": 269,
  "difficulty": "Intermediate",
  "updated_date": "2024-12-02",
  "ratings": 4.8,
  "ratings_count": 1002,
  "certified": true,
  "credits": {
    "CPE": 4.1,
    "PDU": 1.5
  }
}
```

Files are saved relative to the output and cache paths respectively.

## Performance

- Cache prevents re-fetching the same course details and dramatically shortens subsequent runs.
- The first run (cold cache) is the slowest, after that, most runs should complete in seconds or a couple of minutes depending on what changed.
- Each course takes approximately 4 seconds to scrape, or approximately 1.5 seconds per learning path. Rate limits/errors take place typically every 5-10 course pages, but nearly never on learning.

Assuming no cached data, you can expect 100 courses to typically aggregate in 10 minutes. If you expect to run this often, keep the cache directory persistent and back it up if you care about the extracted history.

## Troubleshooting

- Login problems / 2FA: Use the Chrome Default profile path where you're already logged in — this is the simplest. Supplying credentials directly can trigger extra checks or 2FA.
- Chrome/Chromedriver mismatch: Make sure chromedriver matches your Chrome version; mismatches cause selenium to fail early.
- Frequent failures or temporary bans: Slow down the delays and increase refresh/backoff intervals. Reduce concurrency (the script is single-threaded by default).
- Missing fields: LinkedIn occasionally changes page structure. If you see missing fields, the scraper may need a small selector update.
- Huge histories: The script is tolerant of many courses, but consider running overnight and relying on cache for incremental updates.

## License

LinkedIn Ruby (again, not the website) is licensed under [AGPL 3.0](LICENSE.txt).
