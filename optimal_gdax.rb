require 'gdax'

class OptimalGdax
  attr_accessor :coins, :minimum_order_size, :fiat_currency,
    :order_count, :starting_discount, :discount_step,
    :addresses

  def initialize(options = {})
    @addresses = {
      'BTC': '139zv1TFLiQ2wWzF3SprL5jAn2PkSyRqaj',
      'ETH': '0x47948f54fAF97B33708716973bB577927de897A1',
      'LTC': 'Ld2dy9RAGe1waaMcLAo7XboTwsPBnS7EkU',
    }
    @coins = {
      'BTC': 'Bitcoin',
      'ETH': 'Ethereum',
      'LTC': 'Litecoin',
    }
    @minimum_order_size = {
      'BTC': 0.0001,
      'ETH': 0.001,
      'LTC': 0.01,
    }
    @fiat_currency = 'USD'
    @discount_step = options[:discount_step] || 0.01
    @starting_discount = options[:starting_discount] || 0.005
    @order_count = options[:order_count] || 5
  end

  def get_products
    @products ||= begin
      products = GDAX::Product.list
      products.each do |product|
        if coins.keys.include?(product.base_currency) && product.quote_currency == fiat_currency
          minimum_order_size[product.base_currency] = Decimal(product.base_min_size)
        end
      end

      products
    end
  end

  def get_prices
    @prices ||= begin
      prices = {}
      GDAX::Product.list.each do |product|
        ticker = product.ticker
        prices[product.base_currency] = Decimal(ticker.price)
      end
      prices
    end
  end

  def get_fiat_balances(accounts, prices)
    balances = {}
    accounts.each do |a|
      if a['currency'] == fiat_currency
        balances[fiat_currency] = Decimal(a.balance)
      else
        balances[a.currency] = Decimal(a.balance * prices[a.currency])
      end
    end
    balances
  end

  def buy
    pp('Starting buy and (maybe) withdrawal')
    pp('First, cancelling orders')
    products = get_products
    pp products
    GDAX::Order.cancel_all
    # Check if there's any fiat available to execute a buy
    accounts =  GDAX::Account.list
    prices = get_prices
    pp accounts
    pp prices

    fiat_balances = get_fiat_balances(accounts, prices)
    pp fiat_balances

    if fiat_balances[fiat_currency] > withdrawal_amount
      pp "fiat balance above 100 #{fiat_currency}, buying more"
      start_buy_orders(accounts, prices, fiat_balances)
    else
      pp "Only #{fiat_balances[fiat_currency]} #{fiat_currency} balance remaining, withdrawing coins without buying"
      withdraw(accounts)
    end
  end

  def start_buy_orders(accounts, prices, fiat_balances, fiat_amount)
    # Determine amount of each coin, in fiat, to buy
    fiat_balance_sum = fiat_balances.values.inject(0){|sum,x| sum + x }
    pp 'fiat_balance_sum'
    pp fiat_balance_sum

    target_amount_fiat = {}
    coins.each do |c|
      target_amount_fiat[c] = fiat_balance_sum * weights[c]
    end

    pp 'target_amount_fiat'
    pp target_amount_fiat

    balance_differences_fiat = {}
    coins.each do |c|
      balance_differences_fiat[c] = (100 * (target_amount_fiat[c] - fiat_balances[c])).floor / 100.0
    end
    pp 'balance_differences_fiat'
    pp balance_differences_fiat

    # Calculate portion of each to buy
    sum_to_buy = 0
    balance_differences_fiat.each do |coin, balance|
      sum_to_buy += balance if balance >= 0
    end

    amount_to_buy = {}
    balance_differences_fiat.each do |coin, balance|
      amount_to_buy[coin] = (balance / sum_to_buy) * fiat_amount
    end

    pp 'amount_to_buy'
    pp amount_to_buy

    coins.each do |c|
      place_buy_orders(amount_to_buy[c], c, prices[c])
    end
  end

  def place_buy_orders(balance_difference_fiat, coin, price)
    if balance_difference_fiat <= 0.01
      pp "#{coin}: balance_difference_fiat=#{balance_difference_fiat}, not buying #{coin}"
      return
    end

    if price <= 0
      pp "price=#{price}, not buying #{coin}"
      return
    end

    # If the size is <= minimum * 5, set a single buy order, because otherwise
    # it will get rejected
    if ((balance_difference_fiat / price) <= (minimum_order_size[coin] * order_count))
      discount = 1 - starting_discount
      amount = balance_difference_fiat
      discounted_price = price * discount
      size = amount / discounted_price
      set_buy_order(coin, discounted_price, size)
    else
      # Set 5 buy orders, in 1% discount increments, starting from 0.5% off
      amount = (100 * balance_difference_fiat / args.order_count).floor / 100.0
      discount = 1 - starting_discount
      5.times do
        discounted_price = price * discount
        size = amount / discounted_price
        set_buy_order(coin, discounted_price, size)
        discount = discount - discount_step
      end
    end
  end

  def set_buy_order(coin, price, size)
    pp "placing order coin=#{coin} price=#{price} size=#{size}"
    order = GDAX::Order.buy(
      product_id: "#{coin}-#{fiat_currency}",
      price: price, size: size,
      type: 'limit',
      post_only: true
    )
    pp "order=#{order}"
    order
  end

  def get_account(accounts, currency)
    accounts.find do |a|
      a['currency'] == currency
    end
  end

  def withdraw(accounts)
    # Check that we've got addresses
    unless addresses
      pp 'No withdraw address specified.'
    end

    coins.each do |coin, name|
      account = get_account(accounts, coin)
      if Decimal(account['balance']) < 0.01
        pp "#{coin} balance only #{account['balance']}, not withdrawing"
      else
        execute_withdrawal(account['balance'], coin, addresses[coin])
      end
    end
  end

  def execute_withdrawal(amount, currency, crypto_address)
    # The GDAX API does something goofy where the account balance
    # has more decimal places than the withdrawal API supports, so
    # we have to account for that here
    amount = Decimal(amount)
    pp "withdrawing #{amount} #{currency} to #{crypto_address}"
    transaction = GDAX::Withdrawal.crypto(address: crypto_address, currency: currency, amount: amount)

    pp transaction
  end

  def weights
    @weights ||= begin
      market_cap = {}
      coins.each do |key, val|
        ticker = Coinmarketcap.coin(key)
        market_cap[key] = Decimal(ticker[0]['market_cap_usd'])
      end

      total_market_cap = market_cap.values.inject(0){|sum,x| sum + x }

      weights = {}
      coins.each do |key, val|
        weights[key] = market_cap[key] / total_market_cap
      end

      pp "Coin weights: #{weights}"
      weights
    end
  end
end
