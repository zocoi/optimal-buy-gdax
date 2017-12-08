require_relative 'optimal_gdax'
require 'gdax'
require 'thor'
require 'dotenv/load'

class GdaxCli < Thor
  desc "buy <api_key> <api_secret> <api_passphrase>", "Buy from GDAX"
  def buy(api_key=nil, api_secret=nil, api_passphrase=nil)
    GDAX.api_key = api_key || ENV['GDAX_API_KEY']
    GDAX.api_secret = api_secret || ENV['GDAX_API_SECRET']
    GDAX.api_passphrase = api_passphrase || ENV['GDAX_API_PASSPHRASE']
    binding.pry
    gdax = OptimalGdax.new
    gdax.buy
  end
end

GdaxCli.start(ARGV)
