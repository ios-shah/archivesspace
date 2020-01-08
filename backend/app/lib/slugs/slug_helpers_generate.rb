module SlugHelpers

  def self.cache
    @@cache ||= Set.new
  end

  def self.cache_reset
    @@cache = Set.new
  end

  # preload manually generated slugs into the cache
  def self.cache_setup
    slug_record_types.each do |klass|
      cache.merge(
        klass.where(Sequel.~(slug: nil), is_slug_auto: 0).select_map(:slug)
      )
    end
  end

  def self.job_running(status: false)
    status == true ? cache_setup : cache_reset
    @@running = status
  end

  def self.job_running?
    @@running ||= false
  end

  # for the generate_slugs_runner job:
  # clear out previously autogenerated slugs so we don't have to lookup if
  # generated slugs are in use from before this job was run
  # (cache_setup preloads manually created slugs)
  def self.reset_autogenerated_slugs
    slug_record_types.each do |klass|
      klass.where(Sequel.~(slug: nil), is_slug_auto: 1).update(slug: nil)
    end
  end

  # remove invalid chars and truncate slug
  # NOTE: If changes are made here, then they should be also made in
  # migration 120 and spec_slugs_helper.rb
  def self.clean_slug(slug)

    if slug
      # if the slug contains two slashes (forward or backward) next to each other, completely zero it out.
      # this is intended to revert an entity to use the URI if the ID or name the slug was generated from is a URI.
      slug = "" if slug =~ /\/\// || slug =~ /\\/

      # remove markup tags
      slug = slug.gsub(/<\/?[^>]*>/, "")

      # downcase everything to simplify case sensitivity issues
      slug = slug.downcase

      # replace spaces with underscores
      slug = slug.gsub(" ", "_")

      # remove double hypens
      slug = slug.gsub("--", "")

      # remove en and em dashes
      slug = slug.gsub(/[\u2013-\u2014]/, "")

      # remove single quotes
      slug = slug.gsub("'", "")

      # remove URL-reserved chars
      slug = slug.gsub(/[&;?$<>#%{}|\\^~\[\]`\/\*\(\)@=:+,!.]/, "")

      # enforce length limit of 50 chars
      slug = slug.slice(0, 50)

      # replace any multiple underscores with a single underscore
      slug = slug.gsub(/_[_]+/, "_")

      # remove any leading or trailing underscores
      slug = slug.gsub(/^_/, "").gsub(/_$/, "")

      # if slug is numeric, add a leading '__'
      # this is necessary, because numerical slugs will be interpreted as an id by the controller
      if slug.match(/^(\d)+$/)
        slug = slug.prepend("__")
      end

    else
      slug = ""
    end

    return slug.parameterize
  end

  # runs dedupe if necessary
  def self.run_dedupe_slug(slug)

    # search for dupes
    if !slug.empty? && slug_in_use?(slug)
      slug = dedupe_slug(slug, 1)
    else
      slug
    end
    cache << slug if job_running?

    slug
  end

  # returns true if the base slug (non-deduped) is different between slug and previous_slug
  # Examples:
  # slug = "foo", previous_slug = "foo_1" => false
  # slug = "foo_123", previous_slug = "foo_123_1" => false
  # slug = "foo_123", previous_slug = "foo_124" => true
  # slug = "foo_123", previous_slug = "foo_124_1" => true
  def self.base_slug_changed?(slug, previous_slug)
    # first, compare the two slugs from left to right to see what they have in common. Remove anything in common.
    # Then, remove anything that matches the pattern of underscore followed by digits, like _1, _2, or _314159, etc that would indicate a deduping suffix
    # if there is nothing left, then the base slugs are the same.

    # the base slug has changed if previous_slug is nil/empty but slug is not
    if (previous_slug.nil? || previous_slug.empty?) &&
       (!slug.nil? && !slug.empty?)
      return true
    end

    # the base slug has changed if slug is nil/empty but previous_slug is not
    if (slug.nil? || slug.empty?) &&
       (!previous_slug.nil? && !previous_slug.empty?)
      return true
    end

    # if we're at this point, then one of the two slugs is not nil or empty.
    # We need to ensure we're calling the following gsubs on a non empty string.
    if previous_slug.nil? || previous_slug.empty?
      check_on = slug
      check_with = previous_slug
    else
      check_on = previous_slug
      check_with = slug
    end

    slug_difference = check_on.gsub(/^#{check_with}/, "")
                              .gsub(/_\d+$/, "")

    # the base slug has changed if there is something left over in slug_difference
    return !slug_difference.empty?
  end

  # given a slug, return true if slug is used by another entity.
  # return false otherwise.
  def self.slug_in_use?(slug)

    if job_running?
      cache.include? slug
    else
      (slug_record_types + [Repository]).inject(0) {|count, klass| count + klass.where(:slug => slug).count } > 0
    end
  end

  # dupe_slug is already in use.
  def self.dedupe_slug(dupe_slug, count)

    new_slug = "#{dupe_slug}_#{count}"
    loop do
      break unless slug_in_use?(new_slug)
      new_slug = "#{dupe_slug}_#{count += 1}"
    end

    new_slug
  end
end
