# frozen_string_literal: true

require "mysql2"
require "time"
require "date"

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::FLARUM < ImportScripts::Base
  #SET THE APPROPRIATE VALUES FOR YOUR MYSQL CONNECTION
  FLARUM_HOST ||= ENV["FLARUM_HOST"] || "db_host"
  FLARUM_DB ||= ENV["FLARUM_DB"] || "db_name"
  BATCH_SIZE ||= 1000
  FLARUM_USER ||= ENV["FLARUM_USER"] || "db_user"
  FLARUM_PW ||= ENV["FLARUM_PW"] || "db_user_pass"
  ATTACHMENTS_BASE_DIR ||= ENV["ATTACHMENTS_BASE_DIR"] || nil # "/absolute/path/to/attachments" set the absolute path if you have attachments

  def initialize
    super

    @htmlentities = HTMLEntities.new

    @client =
      Mysql2::Client.new(
        host: FLARUM_HOST,
        username: FLARUM_USER,
        password: FLARUM_PW,
        database: FLARUM_DB,
      )
  end

  def execute
    import_users
    import_avatars
    import_categories
    import_posts
  end

  def import_users
    puts "", "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "SELECT id, username, email, joined_at, last_seen_at
         FROM users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};",
        )

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        {
          id: user["id"],
          email: user["email"],
          username: user["username"],
          name: user["username"],
          created_at: user["joined_at"],
          last_seen_at: user["last_seen_at"],
        }
      end
    end
  end

  def import_avatars
    if ATTACHMENTS_BASE_DIR && File.exist?(ATTACHMENTS_BASE_DIR)
      puts "", "importing user avatars"

      User.find_each do |u|
        next unless u.custom_fields["import_id"]

        r =
          mysql_query(
            "SELECT avatar_url AS photo FROM users WHERE id = #{u.custom_fields["import_id"]};",
          ).first
        next if r.nil?
        photo = r["photo"]
        next unless photo.present?

        # Possible encoded values:
        # 1. tOVWVHpkF4E9mELz.png

        photo_path = "#{ATTACHMENTS_BASE_DIR}/#{photo}"

        if !File.exist?(photo_path)
          puts "Path to avatar file not found! Skipping. #{photo_path}"
          next
        end

        print "."

        upload = create_upload(u.id, photo_path, File.basename(photo_path))
        if upload.persisted?
          u.import_mode = false
          u.create_user_avatar
          u.import_mode = true
          u.user_avatar.update(custom_upload_id: upload.id)
          u.update(uploaded_avatar_id: upload.id)
        else
          puts "Error: Upload did not persist for #{u.username} #{photo_path}!"
        end
      end
    end
  end

  def find_photo_file(path, base_filename)
    base_guess = base_filename.dup
    full_guess = File.join(path, base_guess) # often an exact match exists

    return full_guess if File.exist?(full_guess)

    # Otherwise, the file exists but with a prefix:
    # The p prefix seems to be the full file, so try to find that one first.
    %w[p t n].each do |prefix|
      full_guess = File.join(path, "#{prefix}#{base_guess}")
      return full_guess if File.exist?(full_guess)
    end

    # Didn't find it.
    nil
  end

  def import_categories
    puts "", "importing top level categories..."

    categories =
      mysql_query(
        "
                              SELECT id, name, description, position
                              FROM tags
                              ORDER BY position ASC
                            ",
      ).to_a

    create_categories(categories) { |category| { id: category["id"], name: category["name"] } }

    puts "", "importing children categories..."

    children_categories =
      mysql_query(
        "
                                       SELECT id, name, description, position
                                       FROM tags
                                       ORDER BY position
                                      ",
      ).to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category["id"]}",
        name: category["name"],
        description: category["description"],
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT p.id id,
               d.id topic_id,
               d.title title,
               d.first_post_id first_post_id,
               p.user_id user_id,
               p.content raw,
               p.created_at created_at,
               t.tag_id category_id
        FROM posts p,
             discussions d,
             discussion_tag t
        WHERE p.discussion_id = d.id
          AND t.discussion_id = d.id
        ORDER BY p.created_at
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ",
        ).to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m["id"].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m["id"]
        mapped[:user_id] = user_id_from_imported_user_id(m["user_id"]) || -1
        mapped[:raw] = process_FLARUM_post(m["raw"], m["id"])
        mapped[:created_at] = Time.zone.at(m["created_at"])

        if m["id"] == m["first_post_id"]
          mapped[:category] = category_id_from_imported_category_id("child##{m["category_id"]}")
          mapped[:title] = CGI.unescapeHTML(m["title"])
        else
          parent = topic_lookup_from_imported_post_id(m["first_post_id"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m["first_post_id"]} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def process_FLARUM_post(raw, import_id)
    s = raw.dup

    s = @htmlentities.decode(s)

    # no idea what <r/> is for... I think it's just wrapping the whole post...
    s.gsub!(%r{</?r>}i, "")

    # paragraph to newline
    s.gsub!(%r{<p>}i, "")
    s.gsub!(%r{</p>}i, "\n")

    # Bold ->
    # <STRONG><s>**</s>...<e>**</e></STRONG>
    # <B><s>[b]</s>...<e>[/b]</e></B>
    s.gsub!(%r{<STRONG><s>\*\*</s>(.*?)<e>\*\*</e></STRONG>}i) { "**#{$1}**" }
    s.gsub!(%r{<B><s>\[b\]</s>(.*?)<e>\[/b\]</e></B>}i) { "**#{$1}**" }

    # Italics ->
    # <EM><s>_</s>...<e>_</e></EM>
    # <I><s>[i]</s>...<e>[/i]</e></I>
    s.gsub!(%r{<EM><s>_</s>(.*?)<e>_</e></EM>}i) { "*#{$1}*" }
    s.gsub!(%r{<I><s>\[i\]</s>(.*?)<e>\[/i\]</e></I>}i) { "*#{$1}*" }

    # Underline ->
    # <U><s>[u]</s>...<e>[/u]</e></U>
    s.gsub!(%r{<U><s>\[u\]</s>(.*?)<e>\[/u\]</e></U>}i) { "[u]#{$1}[/u]" }

    # Strikethrough ->
    # <S><s>[s]</s>...<e>[/s]</e></S>
    s.gsub!(%r{<S><s>\[s\]</s>(.*?)<e>\[/s\]</e></S>}i) { "[s]#{$1}[/s]" }

    # Inline Code -> <C><s>`</s>login<e>`</e></C>
    s.gsub!(%r{<C><s>`</s>(.*?)<e>`</e></C>}i) { "`#{$1}`" }

    # Codeblock -> <CODE><s>[code]</s>...<e>[/code]</e></CODE>
    # Pre is also code -> [pre]...[/pre]
    s.gsub!(%r{<CODE><s>\[code\]</s>(.*?)<e>\[/code\]</e></CODE>}i) { "[code]#{$1}[/code]" }
    s.gsub!(%r{\[pre\](.*?)\[/pre\]}i) { "[code]#{$1}[/code]" }

    # Headings -> <H3><s>### </s>...<e> </e></H3>
    # sometimes the closing <e></e> is absent
    s.gsub!(%r{<H3><s>### </s>}i, "### ")
    s.gsub!(%r{(<e> </e>)?</H3>}i, "")

    # URLS -> two forms
    # <URL url=".1."><s>[</s>.2.<e>](...)</e></URL>
    # <URL url=".1.">.2.</URL>
    s.gsub!(%r{<URL url="(.+?)">(?:<s>.*?</s>)?(.+?)(<e>.*?</e>)?</URL>}i) { "[#{$2}](#{$1})" }

    # Lists
    # unordered <LIST><LI><s>- </s>...</LI><LI><s>- </s>...</LI><LI><s>- </s>...</LI></LIST>
    # ordered <LIST type="decimal"><LI><s>1. </s>...</LI><LI><s>2. </s>...</LI><LI><s>3. </s>...</LI><LI><s>4. </s>...</LI></LIST>
    s.gsub!(%r{<LIST>(.*?)</LIST>}m) { "[ul]#{$1}[/ul]" }
    s.gsub!(%r{<LIST type="decimal">(.*?)</LIST>}m) { "[ol]#{$1}[/ol]" }
    s.gsub!(%r{<LI><s>.*?</s>(.*?)</LI>}i) { "[li]#{$1}[/li]" }

    # Quote -> <QUOTE><s>\n[quote]</s>...<e>[/quote]\n\n</e></QUOTE>
    # safer to use a multiline quote than a ">"
    s.gsub!(%r{<QUOTE><s>.*?</s>(.+?)<e>.*?</QUOTE>}im) { "[quote]\n#{$1}\n[/quote]" }

    # Images -> <IMG src="..."><s>[img]</s>...<e>[/img]</e></IMG>
    s.gsub!(%r{<IMG.*?</s>(.+?)<e>.*?</IMG>}im) { "[img]#{$1}[/img]" }

    # unsupported things
    # <SIZE size=".."><s>[size=..]</s>...<e>[/size]</e></SIZE><br/>
    # <COLOR color=".."><s>[color=..]</s>...<e>[/color]</e></COLOR>
    # <CENTER><s>[center]</s>...<e>[/center]</e></CENTER>
    s.gsub!(%r{<SIZE.*?</s>(.*?)<e>.*?</SIZE>}im, '\1')
    s.gsub!(%r{<COLOR.*?</s>(.*?)<e>.*?</COLOR>}im, '\1')
    s.gsub!(%r{<CENTER.*?</s>(.*?)<e>.*?</CENTER>}im, '\1')



    puts "After"
    puts s

    s
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::FLARUM.new.perform
