require "octokit"
require 'net/http'
require 'json'

class BulkMerger
  def self.approve_unreviewed_pull_requests!(list: nil)
    puts "Searching for PRs containing '#{query_string}' in repositories whose name contains #{repo_string}"

    unreviewed_pull_requests = find_govuk_pull_requests("review:none #{query_string}","#{repo_string}")

    if unreviewed_pull_requests.size == 0
      puts "No unreviewed PRs found!"
      return
    end

    puts "Found #{unreviewed_pull_requests.size} unreviewed PRs:\n\n"

    unreviewed_pull_requests.each do |pr|
      puts "- '#{pr.title}' (#{pr.html_url}) "
    end

    return if list

    puts "\nHave you reviewed the changes, and do you want to approve all these PRs? [y/N]\n"
    if STDIN.gets.chomp == "y"
      puts "OK! 👍 Approving away..."
    else
      puts "👋"
      exit 1
    end

    unreviewed_pull_requests.each do |pr|
      print "Reviewing PR '#{pr.title}' (#{pr.html_url}) "

      repo = pr.repository_url.gsub("https://api.github.com/repos/", "")
      begin
        client.create_pull_request_review(repo, pr.number, event: "APPROVE")
        puts "✅"
      rescue Octokit::Error => e
        puts "❌ Failed to approve: #{e.message.inspect}"
      end
    end
  end

  def self.merge_approved_pull_requests!
    unmerged_pull_requests = find_govuk_pull_requests("review:approved #{query_string}","#{repo_string}")

    if unmerged_pull_requests.size == 0
      puts "No unmerged PRs found!"
      return
    end

    puts "Found #{unmerged_pull_requests.size} reviewed but unmerged PRs:\n\n"

    unmerged_pull_requests.each do |pr|
      puts "- '#{pr.title}' (#{pr.html_url}) "
    end

    puts "\nHave you reviewed the changes, and do you want to MERGE all these PRs? [y/N]\n"
    if STDIN.gets.chomp == "y"
      unmerged_pull_requests.each do |pr|
        repo = pr.repository_url.gsub("https://api.github.com/repos/", "")
        if merge_queue_enabled?(repo)
          begin
            pull_request_id = get_pull_request_id(repo, pr.number)
            add_to_merge_queue(repo, pull_request_id)
            puts "✅ Added PR '#{pr.title}' to the merge queue"
          rescue => e
            puts "❌ Failed to add PR '#{pr.title}' to the merge queue: #{e.message}"
          end
        else
          begin
            client.merge_pull_request(repo, pr.number)
            puts "✅ Merged PR '#{pr.title}'"
          rescue Octokit::Error => e
            puts "❌ Failed to merge: #{e.message.inspect}"
          end
        end
      end
    else
      puts "Aborted. No PRs were processed."
    end
  end

  def self.search_pull_requests(query)
    client.search_issues("#{query} archived:false is:pr user:ministryofjustice state:open in:title").items
  end

  def self.govuk_repos(repo_string)
    @govuk_repos ||= client.search_repos("org:ministryofjustice #{repo_string} in:name")
      .items
      .reject!(&:archived)
      .map { |repo| repo.full_name }
  end

  def self.find_govuk_pull_requests(query,repo_string)
    search_pull_requests(query).select do |pr|
      govuk_repos(repo_string).any? { |repo| pr.repository_url.include?(repo) }
    end
  end

  def self.client
    @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: true)
  end

  def self.query_string
    ENV.fetch("QUERY_STRING")
  end

  def self.repo_string
    ENV.fetch("REPO_STRING")
  end

  # Checks repository for merge queue enabled
  def self.merge_queue_enabled?(repo)
    owner, repo_name = repo.split('/')
  
    query = <<~GRAPHQL
      query {
        repository(owner: "#{owner}", name: "#{repo_name}") {
          mergeQueue {
            id
          }
        }
      }
    GRAPHQL
  
    uri = URI('https://api.github.com/graphql')
    req = Net::HTTP::Post.new(uri, 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}")
    req.body = { query: query }.to_json
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    
    # uncomment below line to see the response from the API
    # puts "Response from merge_queue_enabled?: #{res.body}"

    data = JSON.parse(res.body)
    !data.dig('data', 'repository', 'mergeQueue').nil?
  end

  # Get the pull request ID
  def self.get_pull_request_id(repo, number)
    owner, repo_name = repo.split('/')
  
    query = <<~GRAPHQL
      query {
        repository(owner: "#{owner}", name: "#{repo_name}") {
          pullRequest(number: #{number}) {
            id
          }
        }
      }
    GRAPHQL
  
    uri = URI('https://api.github.com/graphql')
    req = Net::HTTP::Post.new(uri, 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}")
    req.body = { query: query }.to_json
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  
    data = JSON.parse(res.body)
    data.dig('data', 'repository', 'pullRequest', 'id')
  end

  # Adds a PR to the merge queue
  def self.add_to_merge_queue(repo, pull_request_id)
    owner, repo_name = repo.split('/') 
  
    mutation = <<~GRAPHQL
      mutation {
        enqueuePullRequest(input: { pullRequestId: "#{pull_request_id}" }) {
          clientMutationId
        }
      }
    GRAPHQL
  
    uri = URI('https://api.github.com/graphql')
    req = Net::HTTP::Post.new(uri, 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}")
    req.body = { query: mutation }.to_json
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

    # uncomment below line to see the response from the API
    # puts "Response from add_to_merge_queue: #{res.body}"

    data = JSON.parse(res.body)
    data.dig('data', 'enqueuePullRequest', 'clientMutationId')
  end
end
