#!/usr/bin/env ruby
# Coding: UTF-8

Dotenv.load
Bundler.require(ENV["RACK_ENV"]) if ENV["RACK_ENV"]

$LOAD_PATH.unshift(File.expand_path("../lib", __FILE__))

require "digest"
require "sinatra/json_helpers"

class App < Sinatra::Base
  helpers Sinatra::JSONHelpers

  error_logger = ::File.new("#{File.dirname(__FILE__)}/log/#{ENV["RACK_ENV"]}-error.log", "a+")
  error_logger.sync = true

  configure do
    enable :prefixed_redirects
  end

  helpers do
    def redis
      @redis ||= Redis.new
    end

    def block_keys
      %w(prev nonce miner msg datetime).freeze
    end

    def get_block(h)
      block_keys.map{|k| [k, redis.get("#{h}:#{k}")] }.to_h.merge(hash: h)
    end

    def calc_hash(nonce:, prev_block_hash:)
      Digest::SHA256.hexdigest(prev_block_hash + nonce)
    end

    def user_exists?(user)
      redis.sismember "users", user
    end

    def register_user(user)
      redis.sadd "users", user
    end

    def get_all_users
      redis.smembers "users"
    end

    def get_all_block_hashes
      redis.keys("*:datetime").map{|x| x.split(":").first }
    end

    def current_difficulty
      (redis.get("difficulty") || 4).to_i
    end

    def set_difficulty(difficulty)
      redis.set("difficulty", difficulty)
    end

    def current_transfer_charge
      (redis.get("transfer_charge") || 0.1).to_f
    end

    def set_transfer_charge(transfer_charge)
      redis.set("transfer_charge", transfer_charge)
    end

    def parse_msg_as_transfer(msg)
      msg.match(/\A(?<sender>[-_0-9a-zA-Z]{,64}),(?<receiver>[-_0-9a-zA-Z]{,64}),(?<q>[1-9]\d*)\z/)
    end

    def get_prev_hash_of(h)
      prev = redis.get("#{h}:prev")
      (prev.nil? || prev.empty?) ? nil : prev
    end

    def get_balance(user:, h:)
      return 0.0 if h.nil? || h.empty?

      key = "balance:#{user}:#{h}"
      return redis.get(key).to_f if redis.exists(key)

      balance = get_balance(user: user, h: get_prev_hash_of(h))
      redis.set(key, balance)

      balance
    end

    def set_balance(user:, h:, balance:)
      redis.set("balance:#{user}:#{h}", balance)
    end

    def add_balance(user:, h:, diff:)
      orig_balance = get_balance(user: user, h: h)
      set_balance(user: user, h: h, balance: orig_balance + diff)
    end
  end

  options "*" do
    response.headers["Allow"] = "HEAD,GET,POST,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Accept, Authorization, Cache-Control, Content-Type"
    response.headers["Access-Control-Expose-Headers"] = "X-Requested-With, X-HTTP-Method-Override, X-From"
    response.headers["Access-Control-Allow-Credentials"] = "false"

    200
  end

  before do
    env["rack.errors"] = error_logger
  end

  not_found do
    if request.xhr?
      content_type :json
      { error: 'not found' }.to_json
    else
      'Not Found'
    end
  end

  get "/" do
    blocks = redis
      .keys("*:datetime")
      .map {|h| h[0...64] }
      .map {|h| get_block(h) }
      .sort_by {|h| DateTime.parse(h["datetime"]) }

    json ({
      blocks: blocks,
      users: get_all_users
    })
  end

  get "/users/:user_name" do
    user_name = params[:user_name].strip
    unless /\A[-_0-9a-zA-Z]{,64}\z/  === user_name
      halt 400, json({ message: "user_name: must be matched with /\\A[-_0-9a-zA-Z]{,64}\\z/" })
    end

    is_new_user = !(user_exists? user_name)

    register_user(user_name) if is_new_user

    balance = get_all_block_hashes.map {|h| [h, get_balance(user: user_name, h: h)] }.to_h

    json ({
      name: user_name,
      is_new_user: is_new_user,
      balance: balance
    })
  end

  get "/blocks" do
    blocks = redis
      .keys("*:datetime")
      .map {|h| h[0...64] }
      .map {|h| get_block(h) }
      .sort_by {|h| DateTime.parse(h["datetime"]) }

    json blocks
  end

  post "/blocks" do
    required_keys = (block_keys - %w(datetime) - params.keys)

    unless required_keys.empty?
      halt 400, json({ message: "required keys not satisfied: #{required_keys.join(', ')}" })
    end

    prev = params[:prev].downcase
    nonce = params[:nonce]
    miner = params[:miner]
    msg = params[:msg]
    # h = params[:hash].downcase
    h = calc_hash(nonce: nonce, prev_block_hash: prev)

    unless /\A[0-9a-fA-F]{64}\z/ === prev
      halt 400, json({ message: "prev: format is wrong, allowed hash is SHA256 hexdigest" })
    end

    # unless /\A[0-9a-fA-F]{64}\z/ === h
    #   halt 400, json({ message: "hash: format is wrong, allowed hash is SHA256 hexdigest" })
    # end

    unless /\A[0-9a-zA-Z]{,64}\z/ === nonce
      halt 400, json({ message: "nonce: nonce must be matched with /\\A[0-9a-zA-Z]{,64}\\z/" })
    end

    unless /\A[-_0-9a-zA-Z]{,64}\z/ === miner
      halt 400, json({ message: "miner: must be matched with /\\A[-_0-9a-zA-Z]{,64}\\z/" })
    end

    unless user_exists? miner
      halt 400, json({ message: "miner: must be registered" })
    end

    unless redis.exists("#{prev}:datetime")
      halt 422, json({ message: "prev: prev block doesn't exist" })
    end

    if redis.exists("#{h}:datetime")
      halt 409, json({ message: "hash: block with hash #{h} already exists" })
    end

    # if params[:hash] != calc_hash(nonce: nonce, prev_block_hash: prev)
    #   halt 422, json({ message: "hash: block hash is wrong" })
    # end

    given_difficulty = h.match(/\A0+/).to_s.length
    if given_difficulty < current_difficulty
      halt 422, json({ message: "hash: insufficient difficulty. Current difficulty is #{current_difficulty}, given #{given_difficulty}" })
    end

    redis.set("#{h}:prev", prev)
    redis.set("#{h}:nonce", nonce)
    redis.set("#{h}:miner", miner)
    redis.set("#{h}:msg", msg)
    redis.set("#{h}:datetime", DateTime.now.iso8601)

    if matched = parse_msg_as_transfer(msg)
      sender = matched[:sender]
      receiver = matched[:receiver]
      q = matched[:q].to_f

      unless user_exists? sender
        halt 400, json({ message: "sender: user #{sender} must be registered" })
      end

      unless user_exists? receiver
        halt 400, json({ message: "receiver: user #{receiver} must be registered" })
      end

      sender_balance = get_balance(user: sender, h: prev)
      if sender_balance < q
        halt 422, json({ message: "sender: must have at least #{q} to send" })
      end

      if receiver == miner
        halt 422, json({ message: "receiver: must not equal to miner" })
      end

      add_balance(user: sender, h: h, diff: -q)
      charge = q * current_transfer_charge
      add_balance(user: receiver, h: h, diff: q - charge)
      add_balance(user: miner, h: h, diff: charge + given_difficulty)
    else # only mining
      add_balance(user: miner, h: h, diff: given_difficulty)
    end

    json get_block(h)
  end

  # return
  # {
  #   hash: String
  #   last_block_hash: String,
  #   miner: String,
  #   datetime: String,
  #   balance: {
  #     [user]: [balance of user]
  #   }
  # }
  get "/blocks/:hash" do
    h = params[:hash].strip.downcase

    unless /\A[0-9a-f]{64}\z/ === h
      halt 400, json({ message: "hash: format is wrong, allowed hash is SHA256 hexdigest" })
    end

    unless redis.exists "#{h}:datetime"
      halt 404, json({ message: "hash: block with hash #{h} doesn't exist" })
    end

    balance = get_all_users.map {|u| [u, get_balance(user: u, h: h)] }.to_h
    json get_block(h).merge(balance: balance)
  end
end
