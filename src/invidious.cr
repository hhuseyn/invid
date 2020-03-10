# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2019  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"
require "kemal"
require "openssl/hmac"
require "option_parser"
require "pg"
require "sqlite3"
require "xml"
require "yaml"
require "zip"
require "protodec/utils"
require "./invidious/helpers/*"
require "./invidious/*"

CONFIG   = Config.from_yaml(File.read("config/config.yml"))
HMAC_KEY = CONFIG.hmac_key || Random::Secure.hex(32)

ARCHIVE_URL     = URI.parse("https://archive.org")
LOGIN_URL       = URI.parse("https://accounts.google.com")
PUBSUB_URL      = URI.parse("https://pubsubhubbub.appspot.com")
REDDIT_URL      = URI.parse("https://www.reddit.com")
TEXTCAPTCHA_URL = URI.parse("http://textcaptcha.com")
YT_URL          = URI.parse("https://www.youtube.com")
YT_IMG_URL      = URI.parse("https://i.ytimg.com")

CHARS_SAFE         = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
TEST_IDS           = {"AgbeGFYluEA", "BaW_jenozKc", "a9LDPn-MO4I", "ddFvjfvPnqk", "iqKdEhx-dD4"}
MAX_ITEMS_PER_PAGE = 1500

REQUEST_HEADERS_WHITELIST  = {"accept", "accept-encoding", "cache-control", "content-length", "if-none-match", "range"}
RESPONSE_HEADERS_BLACKLIST = {"access-control-allow-origin", "alt-svc", "server"}
HTTP_CHUNK_SIZE            = 10485760 # ~10MB

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/\* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git describe --tags --abbrev=0`.strip}" }}

# This is used to determine the `?v=` on the end of file URLs (for cache busting). We
# only need to expire modified assets, so we can use this to find the last commit that changes
# any assets
ASSET_COMMIT = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit -- assets`.strip}" }}

SOFTWARE = {
  "name"    => "invidious",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

LOCALES = {
  "ar"    => load_locale("ar"),
  "de"    => load_locale("de"),
  "el"    => load_locale("el"),
  "en-US" => load_locale("en-US"),
  "eo"    => load_locale("eo"),
  "es"    => load_locale("es"),
  "eu"    => load_locale("eu"),
  "fr"    => load_locale("fr"),
  "is"    => load_locale("is"),
  "it"    => load_locale("it"),
  "ja"    => load_locale("ja"),
  "nb-NO" => load_locale("nb-NO"),
  "nl"    => load_locale("nl"),
  "pt-BR" => load_locale("pt-BR"),
  "pl"    => load_locale("pl"),
  "ro"    => load_locale("ro"),
  "ru"    => load_locale("ru"),
  "tr"    => load_locale("tr"),
  "uk"    => load_locale("uk"),
  "zh-CN" => load_locale("zh-CN"),
  "zh-TW" => load_locale("zh-TW"),
}

YT_POOL     = QUICPool.new(YT_URL, capacity: CONFIG.pool_size, timeout: 0.05)
YT_IMG_POOL = QUICPool.new(YT_IMG_URL, capacity: CONFIG.pool_size, timeout: 0.05)

config = CONFIG
logger = Invidious::LogHandler.new

Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-c THREADS", "--channel-threads=THREADS", "Number of threads for refreshing channels (default: #{config.channel_threads})") do |number|
    begin
      config.channel_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-f THREADS", "--feed-threads=THREADS", "Number of threads for refreshing feeds (default: #{config.feed_threads})") do |number|
    begin
      config.feed_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-o OUTPUT", "--output=OUTPUT", "Redirect output (default: STDOUT)") do |output|
    FileUtils.mkdir_p(File.dirname(output))
    logger = Invidious::LogHandler.new(File.open(output, mode: "a"))
  end
  parser.on("-v", "--version", "Print version") do |output|
    puts SOFTWARE.to_pretty_json
    exit
  end
end

Kemal::CLI.new ARGV

statistics = {
  "version"  => "2.0",
  "software" => SOFTWARE,
}

decrypt_function = [] of {SigProc, Int32}
spawn do
  update_decrypt_function do |function|
    decrypt_function = function
  end
end

if CONFIG.captcha_key
  spawn do
    bypass_captcha(CONFIG.captcha_key, logger) do |cookies|
      cookies.each do |cookie|
        config.cookies << cookie
      end

      # Persist cookies between runs
      CONFIG.cookies = config.cookies
      File.write("config/config.yml", config.to_yaml)
    end
  end
end

before_all do |env|
  env.response.headers["X-XSS-Protection"] = "1; mode=block;"
  env.response.headers["X-Content-Type-Options"] = "nosniff"

  preferences = CONFIG.default_user_preferences.dup

  locale = env.params.query["hl"]?
  locale ||= "en-US"

  preferences.locale = locale

  env.set "preferences", preferences
end

# API Endpoints

get "/api/v1/stats" do |env|
  env.response.content_type = "application/json"

  if !config.statistics_enabled
    error_message = {"error" => "Statistics are not enabled."}.to_json
    env.response.status_code = 400
    next error_message
  end

  if statistics["error"]?
    env.response.status_code = 500
    next statistics.to_json
  end

  statistics.to_json
end

# YouTube provides "storyboards", which are sprites containing x * y
# preview thumbnails for individual scenes in a video.
# See https://support.jwplayer.com/articles/how-to-add-preview-thumbnails
get "/api/v1/storyboards/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = fetch_video(id, region: region)
  rescue ex : VideoRedirect
    error_message = {"error" => "Video is unavailable", "videoId" => ex.video_id}.to_json
    env.response.status_code = 302
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_message
  rescue ex
    env.response.status_code = 500
    next
  end

  storyboards = video.storyboards

  width = env.params.query["width"]?
  height = env.params.query["height"]?

  if !width && !height
    response = JSON.build do |json|
      json.object do
        json.field "storyboards" do
          generate_storyboards(json, id, storyboards, config, Kemal.config)
        end
      end
    end

    next response
  end

  env.response.content_type = "text/vtt"

  storyboard = storyboards.select { |storyboard| width == "#{storyboard[:width]}" || height == "#{storyboard[:height]}" }

  if storyboard.empty?
    env.response.status_code = 404
    next
  else
    storyboard = storyboard[0]
  end

  String.build do |str|
    str << <<-END_VTT
    WEBVTT


    END_VTT

    start_time = 0.milliseconds
    end_time = storyboard[:interval].milliseconds

    storyboard[:storyboard_count].times do |i|
      host_url = make_host_url(config, Kemal.config)
      url = storyboard[:url].gsub("$M", i).gsub("https://i9.ytimg.com", host_url)

      storyboard[:storyboard_height].times do |j|
        storyboard[:storyboard_width].times do |k|
          str << <<-END_CUE
          #{start_time}.000 --> #{end_time}.000
          #{url}#xywh=#{storyboard[:width] * k},#{storyboard[:height] * j},#{storyboard[:width]},#{storyboard[:height]}


          END_CUE

          start_time += storyboard[:interval].milliseconds
          end_time += storyboard[:interval].milliseconds
        end
      end
    end
  end
end

get "/api/v1/captions/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  # See https://github.com/ytdl-org/youtube-dl/blob/6ab30ff50bf6bd0585927cb73c7421bef184f87a/youtube_dl/extractor/youtube.py#L1354
  # It is possible to use `/api/timedtext?type=list&v=#{id}` and
  # `/api/timedtext?type=track&v=#{id}&lang=#{lang_code}` directly,
  # but this does not provide links for auto-generated captions.
  #
  # In future this should be investigated as an alternative, since it does not require
  # getting video info.

  begin
    video = fetch_video(id, region: region)
  rescue ex : VideoRedirect
    error_message = {"error" => "Video is unavailable", "videoId" => ex.video_id}.to_json
    env.response.status_code = 302
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_message
  rescue ex
    env.response.status_code = 500
    next
  end

  captions = video.captions

  label = env.params.query["label"]?
  lang = env.params.query["lang"]?
  tlang = env.params.query["tlang"]?

  if !label && !lang
    response = JSON.build do |json|
      json.object do
        json.field "captions" do
          json.array do
            captions.each do |caption|
              json.object do
                json.field "label", caption.name.simpleText
                json.field "languageCode", caption.languageCode
                json.field "url", "/api/v1/captions/#{id}?label=#{URI.encode_www_form(caption.name.simpleText)}"
              end
            end
          end
        end
      end
    end

    next response
  end

  env.response.content_type = "text/vtt; charset=UTF-8"

  caption = captions.select { |caption| caption.name.simpleText == label }

  if lang
    caption = captions.select { |caption| caption.languageCode == lang }
  end

  if caption.empty?
    env.response.status_code = 404
    next
  else
    caption = caption[0]
  end

  url = "#{caption.baseUrl}&tlang=#{tlang}"

  # Auto-generated captions often have cues that aren't aligned properly with the video,
  # as well as some other markup that makes it cumbersome, so we try to fix that here
  if caption.name.simpleText.includes? "auto-generated"
    caption_xml = YT_POOL.client &.get(url).body
    caption_xml = XML.parse(caption_xml)

    webvtt = String.build do |str|
      str << <<-END_VTT
      WEBVTT
      Kind: captions
      Language: #{tlang || caption.languageCode}


      END_VTT

      caption_nodes = caption_xml.xpath_nodes("//transcript/text")
      caption_nodes.each_with_index do |node, i|
        start_time = node["start"].to_f.seconds
        duration = node["dur"]?.try &.to_f.seconds
        duration ||= start_time

        if caption_nodes.size > i + 1
          end_time = caption_nodes[i + 1]["start"].to_f.seconds
        else
          end_time = start_time + duration
        end

        start_time = "#{start_time.hours.to_s.rjust(2, '0')}:#{start_time.minutes.to_s.rjust(2, '0')}:#{start_time.seconds.to_s.rjust(2, '0')}.#{start_time.milliseconds.to_s.rjust(3, '0')}"
        end_time = "#{end_time.hours.to_s.rjust(2, '0')}:#{end_time.minutes.to_s.rjust(2, '0')}:#{end_time.seconds.to_s.rjust(2, '0')}.#{end_time.milliseconds.to_s.rjust(3, '0')}"

        text = HTML.unescape(node.content)
        text = text.gsub(/<font color="#[a-fA-F0-9]{6}">/, "")
        text = text.gsub(/<\/font>/, "")
        if md = text.match(/(?<name>.*) : (?<text>.*)/)
          text = "<v #{md["name"]}>#{md["text"]}</v>"
        end

        str << <<-END_CUE
        #{start_time} --> #{end_time}
        #{text}


        END_CUE
      end
    end
  else
    webvtt = YT_POOL.client &.get("#{url}&format=vtt").body
  end

  if title = env.params.query["title"]?
    # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
    env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.encode_www_form(title)}\"; filename*=UTF-8''#{URI.encode_www_form(title)}"
  end

  webvtt
end

get "/api/v1/comments/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]

  source = env.params.query["source"]?
  source ||= "youtube"

  thin_mode = env.params.query["thin_mode"]?
  thin_mode = thin_mode == "true"

  format = env.params.query["format"]?
  format ||= "json"

  continuation = env.params.query["continuation"]?
  sort_by = env.params.query["sort_by"]?.try &.downcase

  if source == "youtube"
    sort_by ||= "top"

    begin
      comments = fetch_youtube_comments(id, continuation, format, locale, thin_mode, region, sort_by: sort_by)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end

    next comments
  elsif source == "reddit"
    sort_by ||= "confidence"

    begin
      comments, reddit_thread = fetch_reddit_comments(id, sort_by: sort_by)
      content_html = template_reddit_comments(comments, locale)

      content_html = fill_links(content_html, "https", "www.reddit.com")
      content_html = replace_links(content_html)
    rescue ex
      comments = nil
      reddit_thread = nil
      content_html = ""
    end

    if !reddit_thread || !comments
      env.response.status_code = 404
      next
    end

    if format == "json"
      reddit_thread = JSON.parse(reddit_thread.to_json).as_h
      reddit_thread["comments"] = JSON.parse(comments.to_json)

      next reddit_thread.to_json
    else
      response = {
        "title"       => reddit_thread.title,
        "permalink"   => reddit_thread.permalink,
        "contentHtml" => content_html,
      }

      next response.to_json
    end
  end
end

get "/api/v1/insights/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  id = env.params.url["id"]
  env.response.content_type = "application/json"

  error_message = {"error" => "YouTube has removed publicly available analytics."}.to_json
  env.response.status_code = 410
  error_message
end

get "/api/v1/annotations/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "text/xml"

  id = env.params.url["id"]
  source = env.params.query["source"]?
  source ||= "archive"

  if !id.match(/[a-zA-Z0-9_-]{11}/)
    env.response.status_code = 400
    next
  end

  annotations = ""

  case source
  when "archive"
    index = CHARS_SAFE.index(id[0]).not_nil!.to_s.rjust(2, '0')

    # IA doesn't handle leading hyphens,
    # so we use https://archive.org/details/youtubeannotations_64
    if index == "62"
      index = "64"
      id = id.sub(/^-/, 'A')
    end

    file = URI.encode_www_form("#{id[0, 3]}/#{id}.xml")

    client = make_client(ARCHIVE_URL)
    location = client.get("/download/youtubeannotations_#{index}/#{id[0, 2]}.tar/#{file}")

    if !location.headers["Location"]?
      env.response.status_code = location.status_code
    end

    response = make_client(URI.parse(location.headers["Location"])).get(location.headers["Location"])

    if response.body.empty?
      env.response.status_code = 404
      next
    end

    if response.status_code != 200
      env.response.status_code = response.status_code
      next
    end

    annotations = response.body
  when "youtube"
    response = YT_POOL.client &.get("/annotations_invideo?video_id=#{id}")

    if response.status_code != 200
      env.response.status_code = response.status_code
      next
    end

    annotations = response.body
  end

  etag = sha256(annotations)[0, 16]
  if env.request.headers["If-None-Match"]?.try &.== etag
    env.response.status_code = 304
  else
    env.response.headers["ETag"] = etag
    annotations
  end
end

get "/api/v1/videos/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = fetch_video(id, region: region)
  rescue ex : VideoRedirect
    error_message = {"error" => "Video is unavailable", "videoId" => ex.video_id}.to_json
    env.response.status_code = 302
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_message
  rescue ex
    error_message = {"error" => ex.message}.to_json
    env.response.status_code = 500
    next error_message
  end

  video.to_json(locale, config, Kemal.config, decrypt_function)
end

get "/api/v1/trending" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  region = env.params.query["region"]?
  trending_type = env.params.query["type"]?

  begin
    trending, plid = fetch_trending(trending_type, region, locale)
  rescue ex
    error_message = {"error" => ex.message}.to_json
    env.response.status_code = 500
    next error_message
  end

  videos = JSON.build do |json|
    json.array do
      trending.each do |video|
        video.to_json(locale, config, Kemal.config, json)
      end
    end
  end

  videos
end

get "/api/v1/channels/:ucid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]
  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "newest"

  begin
    channel = get_about_info(ucid, locale)
  rescue ex : ChannelRedirect
    error_message = {"error" => "Channel is unavailable", "authorId" => ex.channel_id}.to_json
    env.response.status_code = 302
    env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
    next error_message
  rescue ex
    error_message = {"error" => ex.message}.to_json
    env.response.status_code = 500
    next error_message
  end

  page = 1
  if channel.auto_generated
    videos = [] of SearchVideo
    count = 0
  else
    begin
      videos, count = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end
  end

  JSON.build do |json|
    # TODO: Refactor into `to_json` for InvidiousChannel
    json.object do
      json.field "author", channel.author
      json.field "authorId", channel.ucid
      json.field "authorUrl", channel.author_url

      json.field "authorBanners" do
        json.array do
          if channel.banner
            qualities = {
              {width: 2560, height: 424},
              {width: 2120, height: 351},
              {width: 1060, height: 175},
            }
            qualities.each do |quality|
              json.object do
                json.field "url", channel.banner.not_nil!.gsub("=w1060-", "=w#{quality[:width]}-")
                json.field "width", quality[:width]
                json.field "height", quality[:height]
              end
            end

            json.object do
              json.field "url", channel.banner.not_nil!.split("=w1060-")[0]
              json.field "width", 512
              json.field "height", 288
            end
          end
        end
      end

      json.field "authorThumbnails" do
        json.array do
          qualities = {32, 48, 76, 100, 176, 512}

          qualities.each do |quality|
            json.object do
              json.field "url", channel.author_thumbnail.gsub(/=\d+/, "=s#{quality}")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "subCount", channel.sub_count
      json.field "totalViews", channel.total_views
      json.field "joined", channel.joined.to_unix
      json.field "paid", channel.paid

      json.field "autoGenerated", channel.auto_generated
      json.field "isFamilyFriendly", channel.is_family_friendly
      json.field "description", html_to_content(channel.description_html)
      json.field "descriptionHtml", channel.description_html

      json.field "allowedRegions", channel.allowed_regions

      json.field "latestVideos" do
        json.array do
          videos.each do |video|
            video.to_json(locale, config, Kemal.config, json)
          end
        end
      end

      json.field "relatedChannels" do
        json.array do
          channel.related_channels.each do |related_channel|
            json.object do
              json.field "author", related_channel.author
              json.field "authorId", related_channel.ucid
              json.field "authorUrl", related_channel.author_url

              json.field "authorThumbnails" do
                json.array do
                  qualities = {32, 48, 76, 100, 176, 512}

                  qualities.each do |quality|
                    json.object do
                      json.field "url", related_channel.author_thumbnail.gsub(/=\d+/, "=s#{quality}")
                      json.field "width", quality
                      json.field "height", quality
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/videos", "/api/v1/channels/videos/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    page = env.params.query["page"]?.try &.to_i?
    page ||= 1
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "newest"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      error_message = {"error" => "Channel is unavailable", "authorId" => ex.channel_id}.to_json
      env.response.status_code = 302
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      next error_message
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end

    begin
      videos, count = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, config, Kemal.config, json)
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/latest", "/api/v1/channels/latest/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    begin
      videos = get_latest_videos(ucid)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, config, Kemal.config, json)
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/playlists", "/api/v1/channels/playlists/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    continuation = env.params.query["continuation"]?
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "last"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      error_message = {"error" => "Channel is unavailable", "authorId" => ex.channel_id}.to_json
      env.response.status_code = 302
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      next error_message
    rescue ex
      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 500
      next error_message
    end

    items, continuation = fetch_channel_playlists(channel.ucid, channel.author, channel.auto_generated, continuation, sort_by)

    JSON.build do |json|
      json.object do
        json.field "playlists" do
          json.array do
            items.each do |item|
              if item.is_a?(SearchPlaylist)
                item.to_json(locale, config, Kemal.config, json)
              end
            end
          end
        end

        json.field "continuation", continuation
      end
    end
  end
end

{"/api/v1/channels/:ucid/comments", "/api/v1/channels/comments/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    thin_mode = env.params.query["thin_mode"]?
    thin_mode = thin_mode == "true"

    format = env.params.query["format"]?
    format ||= "json"

    continuation = env.params.query["continuation"]?
    # sort_by = env.params.query["sort_by"]?.try &.downcase

    begin
      fetch_channel_community(ucid, continuation, locale, config, Kemal.config, format, thin_mode)
    rescue ex
      env.response.status_code = 400
      error_message = {"error" => ex.message}.to_json
      next error_message
    end
  end
end

get "/api/v1/channels/search/:ucid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  count, search_results = channel_search(query, page, ucid)
  JSON.build do |json|
    json.array do
      search_results.each do |item|
        item.to_json(locale, config, Kemal.config, json)
      end
    end
  end
end

get "/api/v1/search" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "relevance"

  date = env.params.query["date"]?.try &.downcase
  date ||= ""

  duration = env.params.query["duration"]?.try &.downcase
  duration ||= ""

  features = env.params.query["features"]?.try &.split(",").map { |feature| feature.downcase }
  features ||= [] of String

  content_type = env.params.query["type"]?.try &.downcase
  content_type ||= "video"

  begin
    search_params = produce_search_params(sort_by, date, content_type, duration, features)
  rescue ex
    env.response.status_code = 400
    error_message = {"error" => ex.message}.to_json
    next error_message
  end

  count, search_results = search(query, page, search_params, region).as(Tuple)
  JSON.build do |json|
    json.array do
      search_results.each do |item|
        item.to_json(locale, config, Kemal.config, json)
      end
    end
  end
end

get "/api/v1/search/suggestions" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  begin
    client = QUIC::Client.new("suggestqueries.google.com")
    client.family = CONFIG.force_resolve || Socket::Family::INET
    client.family = Socket::Family::INET if client.family == Socket::Family::UNSPEC
    response = client.get("/complete/search?hl=en&gl=#{region}&client=youtube&ds=yt&q=#{URI.encode_www_form(query)}&callback=suggestCallback").body

    body = response[35..-2]
    body = JSON.parse(body).as_a
    suggestions = body[1].as_a[0..-2]

    JSON.build do |json|
      json.object do
        json.field "query", body[0].as_s
        json.field "suggestions" do
          json.array do
            suggestions.each do |suggestion|
              json.string suggestion[0].as_s
            end
          end
        end
      end
    end
  rescue ex
    env.response.status_code = 500
    error_message = {"error" => ex.message}.to_json
    next error_message
  end
end

get "/api/v1/playlists/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  plid = env.params.url["plid"]

  offset = env.params.query["index"]?.try &.to_i?
  offset ||= env.params.query["page"]?.try &.to_i?.try { |page| (page - 1) * 100 }
  offset ||= 0

  continuation = env.params.query["continuation"]?

  format = env.params.query["format"]?
  format ||= "json"

  if plid.starts_with? "RD"
    next env.redirect "/api/v1/mixes/#{plid}"
  end

  begin
    playlist = fetch_playlist(plid, locale)
  rescue ex
    env.response.status_code = 404
    error_message = {"error" => "Playlist does not exist."}.to_json
    next error_message
  end

  user = env.get?("user").try &.as(User)
  if !playlist || playlist.privacy.private? && playlist.author != user.try &.email
    env.response.status_code = 404
    error_message = {"error" => "Playlist does not exist."}.to_json
    next error_message
  end

  response = playlist.to_json(offset, locale, config, Kemal.config, continuation: continuation)

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_playlist(response)
    index, next_video = response["videos"].as_a.skip(1).select { |video| !video["author"].as_s.empty? }[0]?.try { |v| {v["index"], v["videoId"]} } || {nil, nil}

    response = {
      "playlistHtml" => playlist_html,
      "index"        => index,
      "nextVideo"    => next_video,
    }.to_json
  end

  response
end

get "/api/v1/mixes/:rdid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  rdid = env.params.url["rdid"]

  continuation = env.params.query["continuation"]?
  continuation ||= rdid.lchop("RD")[0, 11]

  format = env.params.query["format"]?
  format ||= "json"

  begin
    mix = fetch_mix(rdid, continuation, locale: locale)

    if !rdid.ends_with? continuation
      mix = fetch_mix(rdid, mix.videos[1].id)
      index = mix.videos.index(mix.videos.select { |video| video.id == continuation }[0]?)
    end

    mix.videos = mix.videos[index..-1]
  rescue ex
    error_message = {"error" => ex.message}.to_json
    env.response.status_code = 500
    next error_message
  end

  response = JSON.build do |json|
    json.object do
      json.field "title", mix.title
      json.field "mixId", mix.id

      json.field "videos" do
        json.array do
          mix.videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id
              json.field "author", video.author

              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"

              json.field "videoThumbnails" do
                json.array do
                  generate_thumbnails(json, video.id, config, Kemal.config)
                end
              end

              json.field "index", video.index
              json.field "lengthSeconds", video.length_seconds
            end
          end
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_mix(response)
    next_video = response["videos"].as_a.select { |video| !video["author"].as_s.empty? }[0]?.try &.["videoId"]

    response = {
      "playlistHtml" => playlist_html,
      "nextVideo"    => next_video,
    }.to_json
  end

  response
end

get "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{env.params.query}"
end

get "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect env.request.path.lchop("/api/manifest/dash/id")
end

get "/api/manifest/dash/id/:id" do |env|
  env.response.headers.add("Access-Control-Allow-Origin", "*")
  env.response.content_type = "application/dash+xml"

  local = env.params.query["local"]?.try &.== "true"
  id = env.params.url["id"]
  region = env.params.query["region"]?

  # Since some implementations create playlists based on resolution regardless of different codecs,
  # we can opt to only add a source to a representation if it has a unique height within that representation
  unique_res = env.params.query["unique_res"]?.try { |q| (q == "true" || q == "1").to_unsafe }

  begin
    video = fetch_video(id, region)
  rescue ex : VideoRedirect
    next env.redirect env.request.resource.gsub(id, ex.video_id)
  rescue ex
    env.response.status_code = 403
    next
  end

  if dashmpd = video.player_response["streamingData"]?.try &.["dashManifestUrl"]?.try &.as_s
    manifest = YT_POOL.client &.get(URI.parse(dashmpd).full_path).body

    manifest = manifest.gsub(/<BaseURL>[^<]+<\/BaseURL>/) do |baseurl|
      url = baseurl.lchop("<BaseURL>")
      url = url.rchop("</BaseURL>")

      if local
        url = URI.parse(url).full_path
      end

      "<BaseURL>#{url}</BaseURL>"
    end

    next manifest
  end

  adaptive_fmts = video.adaptive_fmts(decrypt_function)

  if local
    adaptive_fmts.each do |fmt|
      fmt["url"] = URI.parse(fmt["url"]).full_path
    end
  end

  audio_streams = video.audio_streams(adaptive_fmts)
  video_streams = video.video_streams(adaptive_fmts).sort_by { |stream| {stream["size"].split("x")[0].to_i, stream["fps"].to_i} }.reverse

  XML.build(indent: "  ", encoding: "UTF-8") do |xml|
    xml.element("MPD", "xmlns": "urn:mpeg:dash:schema:mpd:2011",
      "profiles": "urn:mpeg:dash:profile:full:2011", minBufferTime: "PT1.5S", type: "static",
      mediaPresentationDuration: "PT#{video.length_seconds}S") do
      xml.element("Period") do
        i = 0

        {"audio/mp4", "audio/webm"}.each do |mime_type|
          mime_streams = audio_streams.select { |stream| stream["type"].starts_with? mime_type }
          if mime_streams.empty?
            next
          end

          xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true) do
            mime_streams.each do |fmt|
              codecs = fmt["type"].split("codecs=")[1].strip('"')
              bandwidth = fmt["bitrate"].to_i * 1000
              itag = fmt["itag"]
              url = fmt["url"]

              xml.element("Representation", id: fmt["itag"], codecs: codecs, bandwidth: bandwidth) do
                xml.element("AudioChannelConfiguration", schemeIdUri: "urn:mpeg:dash:23003:3:audio_channel_configuration:2011",
                  value: "2")
                xml.element("BaseURL") { xml.text url }
                xml.element("SegmentBase", indexRange: fmt["index"]) do
                  xml.element("Initialization", range: fmt["init"])
                end
              end
            end
          end

          i += 1
        end

        {"video/mp4", "video/webm"}.each do |mime_type|
          mime_streams = video_streams.select { |stream| stream["type"].starts_with? mime_type }
          next if mime_streams.empty?

          heights = [] of Int32
          xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true, scanType: "progressive") do
            mime_streams.each do |fmt|
              codecs = fmt["type"].split("codecs=")[1].strip('"')
              bandwidth = fmt["bitrate"]
              itag = fmt["itag"]
              url = fmt["url"]
              width, height = fmt["size"].split("x").map { |i| i.to_i }

              # Resolutions reported by YouTube player (may not accurately reflect source)
              height = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144].sort_by { |i| (height - i).abs }[0]
              next if unique_res && heights.includes? height
              heights << height

              xml.element("Representation", id: itag, codecs: codecs, width: width, height: height,
                startWithSAP: "1", maxPlayoutRate: "1",
                bandwidth: bandwidth, frameRate: fmt["fps"]) do
                xml.element("BaseURL") { xml.text url }
                xml.element("SegmentBase", indexRange: fmt["index"]) do
                  xml.element("Initialization", range: fmt["init"])
                end
              end
            end
          end

          i += 1
        end
      end
    end
  end
end

get "/api/manifest/hls_variant/*" do |env|
  manifest = YT_POOL.client &.get(env.request.path)

  if manifest.status_code != 200
    env.response.status_code = manifest.status_code
    next
  end

  local = env.params.query["local"]?.try &.== "true"

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")

  host_url = make_host_url(config, Kemal.config)

  manifest = manifest.body

  if local
    manifest = manifest.gsub("https://www.youtube.com", host_url)
    manifest = manifest.gsub("index.m3u8", "index.m3u8?local=true")
  end

  manifest
end

get "/api/manifest/hls_playlist/*" do |env|
  manifest = YT_POOL.client &.get(env.request.path)

  if manifest.status_code != 200
    env.response.status_code = manifest.status_code
    next
  end

  local = env.params.query["local"]?.try &.== "true"

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")

  host_url = make_host_url(config, Kemal.config)

  manifest = manifest.body

  if local
    manifest = manifest.gsub(/^https:\/\/r\d---.{11}\.c\.youtube\.com[^\n]*/m) do |match|
      path = URI.parse(match).path

      path = path.lchop("/videoplayback/")
      path = path.rchop("/")

      path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
        mimetype = mimetype.split("/")
        mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
      end

      path = path.split("/")

      raw_params = {} of String => Array(String)
      path.each_slice(2) do |pair|
        key, value = pair
        value = URI.decode_www_form(value)

        if raw_params[key]?
          raw_params[key] << value
        else
          raw_params[key] = [value]
        end
      end

      raw_params = HTTP::Params.new(raw_params)
      if fvip = raw_params["hls_chunk_host"].match(/r(?<fvip>\d+)---/)
        raw_params["fvip"] = fvip["fvip"]
      end

      raw_params["local"] = "true"

      "#{host_url}/videoplayback?#{raw_params}"
    end
  end

  manifest
end

# YouTube /videoplayback links expire after 6 hours,
# so we have a mechanism here to redirect to the latest version
get "/latest_version" do |env|
  if env.params.query["download_widget"]?
    download_widget = JSON.parse(env.params.query["download_widget"])

    id = download_widget["id"].as_s
    title = download_widget["title"].as_s

    if label = download_widget["label"]?
      env.redirect "/api/v1/captions/#{id}?label=#{label}&title=#{title}"
      next
    else
      itag = download_widget["itag"].as_s
      local = "true"
    end
  end

  id ||= env.params.query["id"]?
  itag ||= env.params.query["itag"]?

  region = env.params.query["region"]?

  local ||= env.params.query["local"]?
  local ||= "false"
  local = local == "true"

  if !id || !itag
    env.response.status_code = 400
    next
  end

  video = fetch_video(id, region)

  fmt_stream = video.fmt_stream(decrypt_function)
  adaptive_fmts = video.adaptive_fmts(decrypt_function)

  urls = (fmt_stream + adaptive_fmts).select { |fmt| fmt["itag"] == itag }
  if urls.empty?
    env.response.status_code = 404
    next
  elsif urls.size > 1
    env.response.status_code = 409
    next
  end

  url = urls[0]["url"]
  if local
    url = URI.parse(url).full_path.not_nil!
  end

  if title
    url += "&title=#{title}"
  end

  env.redirect url
end

options "/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/videoplayback/*" do |env|
  path = env.request.path

  path = path.lchop("/videoplayback/")
  path = path.rchop("/")

  path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
    mimetype = mimetype.split("/")
    mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
  end

  path = path.split("/")

  raw_params = {} of String => Array(String)
  path.each_slice(2) do |pair|
    key, value = pair
    value = URI.decode_www_form(value)

    if raw_params[key]?
      raw_params[key] << value
    else
      raw_params[key] = [value]
    end
  end

  query_params = HTTP::Params.new(raw_params)

  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{query_params}"
end

get "/videoplayback" do |env|
  query_params = env.params.query

  fvip = query_params["fvip"]? || "3"
  mns = query_params["mn"]?.try &.split(",")
  mns ||= [] of String

  if query_params["region"]?
    region = query_params["region"]
    query_params.delete("region")
  end

  if query_params["host"]? && !query_params["host"].empty?
    host = "https://#{query_params["host"]}"
    query_params.delete("host")
  else
    host = "https://r#{fvip}---#{mns.pop}.googlevideo.com"
  end

  url = "/videoplayback?#{query_params.to_s}"

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  client = make_client(URI.parse(host), region)

  response = HTTP::Client::Response.new(500)
  5.times do
    begin
      response = client.head(url, headers)

      if response.headers["Location"]?
        location = URI.parse(response.headers["Location"])
        env.response.headers["Access-Control-Allow-Origin"] = "*"

        host = "#{location.scheme}://#{location.host}"
        client = make_client(URI.parse(host), region)

        url = "#{location.full_path}&host=#{location.host}#{region ? "&region=#{region}" : ""}"
      else
        break
      end
    rescue Socket::Addrinfo::Error
      if !mns.empty?
        mn = mns.pop
      end
      fvip = "3"

      host = "https://r#{fvip}---#{mn}.googlevideo.com"
      client = make_client(URI.parse(host), region)
    rescue ex
    end
  end

  if response.status_code >= 400
    env.response.status_code = response.status_code
    next
  end

  if url.includes? "&file=seg.ts"
    if CONFIG.disabled?("livestreams")
      env.response.status_code = 403
      error_message = "Administrator has disabled this endpoint."
      next error_message
    end

    begin
      client = make_client(URI.parse(host), region)
      client.get(url, headers) do |response|
        response.headers.each do |key, value|
          if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
            env.response.headers[key] = value
          end
        end

        env.response.headers["Access-Control-Allow-Origin"] = "*"

        if location = response.headers["Location"]?
          location = URI.parse(location)
          location = "#{location.full_path}&host=#{location.host}"

          if region
            location += "&region=#{region}"
          end

          next env.redirect location
        end

        IO.copy(response.body_io, env.response)
      end
    rescue ex
    end
  else
    if query_params["title"]? && CONFIG.disabled?("downloads") ||
       CONFIG.disabled?("dash")
      env.response.status_code = 403
      error_message = "Administrator has disabled this endpoint."
      next error_message
    end

    content_length = nil
    first_chunk = true
    range_start, range_end = parse_range(env.request.headers["Range"]?)
    chunk_start = range_start
    chunk_end = range_end

    if !chunk_end || chunk_end - chunk_start > HTTP_CHUNK_SIZE
      chunk_end = chunk_start + HTTP_CHUNK_SIZE - 1
    end

    client = make_client(URI.parse(host), region)

    # TODO: Record bytes written so we can restart after a chunk fails
    while true
      if !range_end && content_length
        range_end = content_length
      end

      if range_end && chunk_start > range_end
        break
      end

      if range_end && chunk_end > range_end
        chunk_end = range_end
      end

      headers["Range"] = "bytes=#{chunk_start}-#{chunk_end}"

      begin
        client.get(url, headers) do |response|
          if first_chunk
            if !env.request.headers["Range"]? && response.status_code == 206
              env.response.status_code = 200
            else
              env.response.status_code = response.status_code
            end

            response.headers.each do |key, value|
              if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase) && key.downcase != "content-range"
                env.response.headers[key] = value
              end
            end

            env.response.headers["Access-Control-Allow-Origin"] = "*"

            if location = response.headers["Location"]?
              location = URI.parse(location)
              location = "#{location.full_path}&host=#{location.host}#{region ? "&region=#{region}" : ""}"

              env.redirect location
              break
            end

            if title = query_params["title"]?
              # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
              env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.encode_www_form(title)}\"; filename*=UTF-8''#{URI.encode_www_form(title)}"
            end

            if !response.headers.includes_word?("Transfer-Encoding", "chunked")
              content_length = response.headers["Content-Range"].split("/")[-1].to_i64
              if env.request.headers["Range"]?
                env.response.headers["Content-Range"] = "bytes #{range_start}-#{range_end || (content_length - 1)}/#{content_length}"
                env.response.content_length = ((range_end.try &.+ 1) || content_length) - range_start
              else
                env.response.content_length = content_length
              end
            end
          end

          proxy_file(response, env)
        end
      rescue ex
        if ex.message != "Error reading socket: Connection reset by peer"
          break
        else
          client = make_client(URI.parse(host), region)
        end
      end

      chunk_start = chunk_end + 1
      chunk_end += HTTP_CHUNK_SIZE
      first_chunk = false
    end
  end
end

get "/ggpht/*" do |env|
  host = "https://yt3.ggpht.com"
  client = make_client(URI.parse(host))
  url = env.request.path.lchop("/ggpht")

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    client.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

options "/sb/:id/:storyboard/:index" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/sb/:id/:storyboard/:index" do |env|
  id = env.params.url["id"]
  storyboard = env.params.url["storyboard"]
  index = env.params.url["index"]

  if storyboard.starts_with? "storyboard_live"
    host = "https://i.ytimg.com"
  else
    host = "https://i9.ytimg.com"
  end
  client = make_client(URI.parse(host))

  url = "/sb/#{id}/#{storyboard}/#{index}?#{env.params.query}"

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    client.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/s_p/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  host = "https://i9.ytimg.com"
  client = make_client(URI.parse(host))
  url = env.request.resource

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    client.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/yts/img/:name" do |env|
  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(env.request.resource, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/vi/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  if name == "maxres.jpg"
    build_thumbnails(id, config, Kemal.config).each do |thumb|
      if YT_IMG_POOL.client &.head("/vi/#{id}/#{thumb[:url]}.jpg").status_code == 200
        name = thumb[:url] + ".jpg"
        break
      end
    end
  end
  url = "/vi/#{id}/#{name}"

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_IMG_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

error 404 do |env|
  env.response.content_type = "application/json"

  error_message = "404 Not Found"
  {"error" => error_message}.to_json
end

error 500 do |env|
  env.response.content_type = "application/json"

  error_message = "500 Server Error"
  {"error" => error_message}.to_json
end

Kemal.config.powered_by_header = false
add_handler FilteredCompressHandler.new
add_handler APIHandler.new
add_handler DenyFrame.new
add_context_storage_type(Array(String))
add_context_storage_type(Preferences)
add_context_storage_type(User)

Kemal.config.logger = logger
Kemal.config.host_binding = Kemal.config.host_binding != "0.0.0.0" ? Kemal.config.host_binding : CONFIG.host_binding
Kemal.config.port = Kemal.config.port != 3000 ? Kemal.config.port : CONFIG.port
Kemal.run
