# frozen_string_literal: true

require_relative "changelog"

class Release
  module GithubAPI
    def gh_client
      @gh_client ||= begin
        require "netrc"
        _username, token = Netrc.read["api.github.com"]

        require "octokit"
        Octokit::Client.new(:access_token => token)
      end
    end
  end

  module SubRelease
    include GithubAPI

    attr_reader :version, :changelog, :version_files, :title, :tag_prefix

    def cut_changelog_for!(pull_requests)
      set_relevant_pull_requests_from(pull_requests)

      cut_changelog!
    end

    def cut_changelog!
      @changelog.cut!(previous_version, relevant_pull_requests)
    end

    def create_for_github!
      tag = "#{@tag_prefix}#{@version}"

      gh_client.create_release "rubygems/rubygems", tag, :name => tag,
                                                         :body => @changelog.release_notes.join("\n").strip,
                                                         :prerelease => @version.prerelease?
    end

    def previous_version
      @latest_release ||= latest_release.tag_name.gsub(/^#{@tag_prefix}/, "")
    end

    def latest_release
      @latest_release ||= gh_client.releases("rubygems/rubygems").select {|release| release.tag_name.start_with?(@tag_prefix) }.sort_by(&:created_at).last
    end

    attr_reader :relevant_pull_requests

    def set_relevant_pull_requests_from(pulls)
      @relevant_pull_requests = pulls.select {|pull| @changelog.relevant_label_for(pull) }
    end
  end

  class Bundler
    include SubRelease

    def initialize(version)
      @version = version
      @changelog = Changelog.for_bundler(version)
      @version_files = [File.expand_path("../bundler/lib/bundler/version.rb", __dir__)]
      @title = "Bundler version #{version} with changelog"
      @tag_prefix = "bundler-v"
    end
  end

  class Rubygems
    include SubRelease

    def initialize(version)
      @version = version
      @changelog = Changelog.for_rubygems(version)
      @version_files = [File.expand_path("../lib/rubygems.rb", __dir__), File.expand_path("../rubygems-update.gemspec", __dir__)]
      @title = "Rubygems version #{version} with changelog"
      @tag_prefix = "v"
    end
  end

  include GithubAPI

  def self.for_bundler(version)
    rubygems_version = Gem::Version.new(version).segments.map.with_index {|s, i| i == 0 ? s + 1 : s }.join(".")

    release = new(rubygems_version)
    release.set_bundler_as_current_library
    release
  end

  def self.for_rubygems(version)
    release = new(version)
    release.set_rubygems_as_current_library
    release
  end

  #
  # Accepts the version of the rubygems library to be released
  #
  def initialize(version)
    segments = Gem::Version.new(version).segments

    rubygems_version = segments.join(".")
    @rubygems = Rubygems.new(rubygems_version)

    bundler_version = segments.map.with_index {|s, i| i == 0 ? s - 1 : s }.join(".")
    @bundler = Bundler.new(bundler_version)

    @stable_branch = segments[0, 2].join(".")
    @release_branch = "release/bundler_#{bundler_version}_rubygems_#{rubygems_version}"
  end

  def set_bundler_as_current_library
    @current_library = @bundler
  end

  def set_rubygems_as_current_library
    @current_library = @rubygems
  end

  def prepare!
    initial_branch = `git rev-parse --abbrev-ref HEAD`.strip

    system("git", "checkout", "-b", @release_branch, @stable_branch, exception: true)

    @bundler.set_relevant_pull_requests_from(unreleased_pull_requests)
    @rubygems.set_relevant_pull_requests_from(unreleased_pull_requests)

    begin
      prs = relevant_unreleased_pull_requests

      if prs.any? && !system("git", "cherry-pick", "-x", "-m", "1", *prs.map(&:merge_commit_sha))
        warn <<~MSG

          Opening a new shell to fix the cherry-pick errors manually. You can do the following now:

          * Find the PR that caused the merge conflict.
          * If you'd like to include that PR in the release, tag it with an appropriate label. Then type `Ctrl-D` and rerun the task so that the PR is cherry-picked before and the conflict is fixed.
          * If you don't want to include that PR in the release, fix conflicts manually, run `git add . && git cherry-pick --continue` once done, and if it succeeds, run `exit 0` to resume the release preparation.

        MSG

        unless system(ENV["SHELL"] || "zsh")
          system("git", "cherry-pick", "--abort", exception: true)
          raise "Failed to resolve conflicts, resetting original state"
        end
      end

      [@bundler, @rubygems].each do |library|
        library.version_files.each do |version_file|
          version_contents = File.read(version_file)
          unless version_contents.sub!(/^(.*VERSION = )"#{Gem::Version::VERSION_PATTERN}"/i, "\\1#{library.version.to_s.dump}")
            raise "Failed to update #{version_file}, is it in the expected format?"
          end
          File.open(version_file, "w") {|f| f.write(version_contents) }
        end

        library.cut_changelog!

        system("git", "commit", "-am", library.title, exception: true)
      end
    rescue StandardError
      system("git", "checkout", initial_branch, exception: true)
      system("git", "branch", "-D", @release_branch, exception: true)
      raise
    end
  end

  def cut_changelog!
    @current_library.cut_changelog_for!(unreleased_pull_requests)
  end

  private

  def relevant_unreleased_pull_requests
    (@bundler.relevant_pull_requests + @rubygems.relevant_pull_requests).sort_by(&:merged_at)
  end

  def unreleased_pull_requests
    @unreleased_pull_requests ||= scan_unreleased_pull_requests(unreleased_pr_ids)
  end

  def scan_unreleased_pull_requests(ids)
    pulls = gh_client.pull_requests("rubygems/rubygems", :sort => :updated, :state => :closed, :direction => :desc)

    loop do
      pulls.select! {|pull| ids.include?(pull.number) }

      break if (pulls.map(&:number) & ids).to_set == ids.to_set

      pulls.concat gh_client.get(gh_client.last_response.rels[:next].href)
    end

    pulls
  end

  def unreleased_pr_ids
    stable_merge_commit_messages = `git log --format=%s --grep "^Merge pull request #" #{@stable_branch}`.split("\n")

    `git log --oneline --grep "^Merge pull request #" origin/master`.split("\n").map do |l|
      _sha, message = l.split(/\s/, 2)

      next if stable_merge_commit_messages.include?(message)

      /^Merge pull request #(\d+)/.match(message)[1].to_i
    end.compact
  end
end
