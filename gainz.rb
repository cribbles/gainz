#!/usr/bin/env ruby

require "json"
require "open-uri"
require "optparse"
require "set"
require "sqlite3"
require "uri"

# Misc constants
API_PATH_DEFAULT = "price"
API_PATH_HISTORICAL = "pricehistorical"
API_ROOT = "https://min-api.cryptocompare.com/data/"
DB_FILE_NAME = "gainz.db"
EXCHANGE_CURRENCY_DEFAULT = "USD"
NUM_HEADER_PADDING_CHARS = 5
VALID_CURRENCY_REGEX = /^\w{3,5}$/

# Time constants
SECONDS_HOUR = 60 * 60
SECONDS_DAY = SECONDS_HOUR * 24
SECONDS_WEEK = SECONDS_DAY * 7
SECONDS_MONTH = SECONDS_DAY * 30
SECONDS_YEAR = SECONDS_DAY * 365
TIMESTAMP_CONVERSIONS = {
  hour: SECONDS_HOUR,
  day: SECONDS_DAY,
  week: SECONDS_WEEK,
  month: SECONDS_MONTH,
  year: SECONDS_YEAR
}

# Params constants
OPTIONAL_EXCHANGE_PARAMS = {
  currency: [
    "-c",
    "--currency"
  ],
  duration: [
    "-d",
    "--duration"
  ]
}
VALID_DURATIONS = TIMESTAMP_CONVERSIONS.keys

ARGV << '-h' if ARGV.empty?

def abort_on_invalid_username(name)
  if name.nil? || !name.match(/^[\w\d]+$/)
    abort "Couldn't add #{name}: invalid name"
  end
end

def find_or_create_crypto_id(db, symbol)
  result = db.get_first_value <<-SQL
    SELECT id FROM cryptos WHERE symbol = '#{symbol}'
  SQL

  return result if result

  db.execute2(<<-SQL) && db.last_insert_row_id
    INSERT INTO cryptos (symbol) VALUES ('#{symbol}')
  SQL
end

def find_user_id_by_name(db, name)
  user_id = db.get_first_value <<-SQL
    SELECT id FROM users WHERE name = '#{name}'
  SQL

  if !user_id
    abort "Couldn't update balance: user doesn't exist"
  end

  user_id
end

def format_headers(headers)
  headers.map do |header|
    "%-#{header.length + NUM_HEADER_PADDING_CHARS}s"
  end.join(" ")
end

def to_timestamp(duration)
  duration ? Time.now.to_i - TIMESTAMP_CONVERSIONS[duration] : nil
end

def get_api_url(from, to, duration)
  api_path = duration ? API_PATH_HISTORICAL : API_PATH_DEFAULT
  query_params = {
    fsym: to,
    tsyms: from.join(','),
    ts: to_timestamp(duration)
  }.reject { |_, v| v.nil? }
  API_ROOT + api_path + "?" + URI.encode_www_form(query_params)
end

def convert(from, to, duration = nil)
  url = get_api_url(from, to, duration)
  resp = open(url).read
  json = JSON.parse(resp)
  data = duration ? json[to] : json
  conversions = data.map do |(symbol, price)|
    conversion = price > 0 ? 1 / price : 0
    [symbol, conversion]
  end
  Hash[conversions]
end

def get_historical_currency_chunks(symbols)
=begin
CryptoCompare.com's API limits the length of the "fsym" (from) parameter for
historical price checks to 30 characters.

Therefore, we must split the symbols for these requests into separate chunks,
maximizing the number in each request.
=end
  chunks = []
  current_chunk = []
  current_length = 0
  i = 0
  while i < symbols.length
    symbol = symbols[i]
    if current_length + symbol.length > 30
      chunks << current_chunk
      current_chunk = []
      current_length = 0 # account for the comma
    end
    current_chunk << symbol
    current_length += symbol.length + 1
    i += 1
  end
  chunks << current_chunk
end

def get_conversions(options)
  historical_conversions = get_historical_currency_chunks(options[:from])
    .map { |chunk| convert(chunk, options[:to], options[:duration]) }
    .reduce({}) { |conversions, chunk| conversions.merge(chunk) }

  current_conversions = convert(options[:from], options[:to])

  conversions = [current_conversions, historical_conversions]

  if options[:filter_missing_values]
    filter_missing_values(*conversions)
  else
    conversions
  end
end

def filter_missing_values(current_conversions, historical_conversions)
=begin
Filtering zero-value historical conversions is sometimes necessary because
CryptoCompare's API sometimes returns 0 for historical data (either because CC
does not track historical data for the coin, or because the token did not exist
before a certain date).
=end
  non_zero_historical_conversions = historical_conversions.reject do |_, value|
    value.zero?
  end
  non_zero_current_conversions = current_conversions.select do |currency|
    non_zero_historical_conversions.include?(currency)
  end
  [non_zero_current_conversions, non_zero_historical_conversions]
end

def optional_exchange_params
  OPTIONAL_EXCHANGE_PARAMS.map do |(param, flags)|
    "[#{flags.join(", ")} #{param.to_s.upcase}]"
  end.join(" ")
end

def get_optional_exchange_param(param)
  param_index = ARGV.find_index do |arg|
    OPTIONAL_EXCHANGE_PARAMS[param].include?(arg)
  end
  param_index ? ARGV[param_index + 1] : nil
end

def get_duration
  param = get_optional_exchange_param(:duration)
  duration = param ? param.to_sym : :day
  if !VALID_DURATIONS.include?(duration)
    abort "Invalid duration, expected one of: #{VALID_DURATIONS.join(", ")}"
  end
  duration
end

def get_exchange_currency
  (get_optional_exchange_param(:currency) || EXCHANGE_CURRENCY_DEFAULT).upcase
end

def add_trailing_zeros(numeric_string)
  sprintf("%2.2f", numeric_string)
end

def format_price(price)
  rounded = price.round(2)
  add_trailing_zeros(rounded)
end

def format_percent(percent)
  return "-------" if percent == 0
  formatted = (percent > 0 ? "+" : "") + add_trailing_zeros(percent)
  "(#{formatted}%)"
end

def get_percent_change(current, past)
  change = current - past
  ratio = change.fdiv(past)
  (ratio * 100).round(2)
end

parser = OptionParser.new do |parser|
  parser.banner = "Usage: gainz.rb [options]"

  parser.on(
    "-a",
    "--add USER",
    "Add a user"
  ) do |name|
    abort_on_invalid_username(name)

    db = SQLite3::Database.new(DB_FILE_NAME)

    count = db.get_first_value <<-SQL
      SELECT COUNT(*) FROM users WHERE name = '#{name}'
    SQL

    if count > 0
      abort "Couldn't add #{name}: user already exists"
    end

    db.execute <<-SQL
      INSERT INTO users (name) VALUES ('#{name}');
    SQL

    puts "Added user successfully."
  end

  parser.on(
    "-u",
    "--update USER CRYPTO AMOUNT",
    "Update a user's crypto balance"
  ) do |name|
    abort_on_invalid_username(name)

    if ARGV.length < 2
      abort "Couldn't update balance: missing arguments"
    end

    symbol, amount = ARGV

    if !symbol.match(VALID_CURRENCY_REGEX)
      abort "Couldn't update balance: invalid symbol #{name}"
    end

    db = SQLite3::Database.new(DB_FILE_NAME)

    user_id = find_user_id_by_name(db, name)
    crypto_id = find_or_create_crypto_id(db, symbol.upcase)

    if amount.to_f > 0
      db.execute <<-SQL
        INSERT OR REPLACE INTO holdings (user_id, crypto_id, amount)
        VALUES (#{user_id}, #{crypto_id}, #{amount.to_f})
      SQL
    else
      db.execute <<-SQL
        DELETE FROM holdings
        WHERE user_id = '#{user_id}'
        AND crypto_id = '#{crypto_id}'
      SQL
    end

    puts "Updated balance successfully."
  end

  parser.on(
    "-p",
    "--portfolio USER #{optional_exchange_params}",
    "Display a user's portfolio"
  ) do |name|
    abort_on_invalid_username(name)

    duration = get_duration
    exchange_currency = get_exchange_currency

    if (!exchange_currency.match(VALID_CURRENCY_REGEX))
      abort "Couldn't display portfolio: invalid exchange currency"
    end

    db = SQLite3::Database.new(DB_FILE_NAME)

    user_id = find_user_id_by_name(db, name)

    result = db.execute2(<<-SQL).drop(1)
      SELECT c.symbol, h.amount
      FROM holdings h
      LEFT OUTER JOIN cryptos c ON c.id = h.crypto_id
      WHERE user_id = #{user_id}
    SQL

    symbols = result.map(&:first)

    current_conversions, historical_conversions = get_conversions(
      from: symbols,
      to: exchange_currency,
      duration: duration
    )

    changes = symbols.reduce({}) do |changes, symbol|
      percent_change = -> {
        if historical_conversions[symbol] == 0
          0.0
        else
          get_percent_change(
            current_conversions[symbol],
            historical_conversions[symbol]
          )
        end
      }.call
      changes.merge(symbol => percent_change)
    end

    raw_holdings = result.map do |(crypto, amount)|
      [
        current_conversions[crypto] * amount,
        historical_conversions[crypto] * amount
      ]
    end

    holdings = raw_holdings
      .reject { |_, historical| historical.zero? }
      .transpose

    total, historical_total = holdings.map { |h| h.reduce(:+) }

    cryptos = holdings
      .first
      .zip(result)
      .map { |conversion, row| [conversion] + row }
      .sort_by { |(conversion)| -conversion }

    total_percent_change = get_percent_change(total, historical_total)

    puts [
      "USER: #{name}",
      "TOTAL: #{total.round(2)} #{format_percent(total_percent_change)}",
      "\n"
    ].join("\n")

    headers = [
      "Percent",
      "Currency",
      "Price",
      "Change",
      "Holdings",
      "Value (#{exchange_currency})"
    ]
    format = format_headers(headers)
    puts format % headers

    cryptos.each do |(conversion, symbol, amount)|
      percent_of_total = (conversion / total * 100).to_i
      price = format_price(conversion / amount)
      puts format % [
        "#{percent_of_total}%",
        symbol,
        price,
        format_percent(changes[symbol]),
        format_price(amount),
        format_price(conversion)
      ]
    end
  end

  parser.on(
    "-l",
    "--leaderboard #{optional_exchange_params}",
    "Display the current leaderboard",
  ) do
    db = SQLite3::Database.new(DB_FILE_NAME)

    duration = get_duration
    exchange_currency = get_exchange_currency

    num_users = db.get_first_value <<-SQL
      SELECT COUNT(*) FROM users
    SQL

    if num_users == 0
      abort [
        "Couldn't display leaderboard: no user data.",
        "Try running: ./gainz.rb -a USER"
      ].join("\n")
    end

    cryptos = Hash[db.execute2(<<-SQL).drop(1)]
      SELECT id, symbol FROM cryptos
    SQL

    if cryptos.empty?
      abort [
        "Couldn't display leaderboard: no crypto data.",
        "Try running: ./gainz.rb -u USER CRYPTO AMOUNT"
      ].join("\n")
    end

    symbols = cryptos.values
    current_conversions, historical_conversions = get_conversions(
      from: symbols,
      to: exchange_currency,
      duration: duration,
      filter_missing_values: true
    )
    valid_symbols = Set.new(current_conversions.keys)
    valid_crypto_ids = cryptos
      .select { |_, symbol| valid_symbols.include?(symbol) }
      .keys

    holdings = db.execute2(<<-SQL).drop(1)
      SELECT u.name, c.symbol, h.amount
      FROM holdings h
      LEFT OUTER JOIN cryptos c ON c.id = h.crypto_id
      LEFT OUTER JOIN users u ON u.id = h.user_id
      WHERE h.crypto_id IN (#{valid_crypto_ids.join(", ")})
    SQL

    users = holdings.group_by { |(name)| name }.to_a
    user_totals = users.map do |(user, value)|
      get_total = ->(conversions) do
        value.reduce(0) do |total, (_, crypto, amount)|
          total + (conversions[crypto] * amount)
        end
      end
      [
        user,
        get_total.call(current_conversions),
        get_total.call(historical_conversions)
      ]
    end
    sorted_user_totals = user_totals.sort_by { |(_, total)| -total }

    puts "LEADERBOARD\n\n"

    headers = [
      "Ranking",
      "User",
      "Total (#{exchange_currency})",
      "Change"
    ]
    format = format_headers(headers)
    puts format % headers

    sorted_user_totals.each_with_index do |(user, total, historical_total), i|
      percent_change = get_percent_change(total, historical_total)
      puts format % [
        i + 1,
        user,
        total.round(2),
        format_percent(percent_change)
      ]
    end
  end

  parser.on(
    "-h",
    "--help",
    "Show this help message"
  ) do
    puts parser
  end
end

begin
  parser.parse!
rescue OptionParser::InvalidOption => e
  # who cares?
end
