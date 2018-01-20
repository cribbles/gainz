#!/usr/bin/env ruby

require "json"
require "open-uri"
require "optparse"
require "sqlite3"
require "uri"

API_PATH_DEFAULT = "price"
API_PATH_HISTORICAL = "pricehistorical"
API_ROOT = "https://min-api.cryptocompare.com/data/"
DB_FILE_NAME = "gainz.db"
EXCHANGE_CURRENCY_DEFAULT = "USD"
NUM_HEADER_PADDING_CHARS = 5
VALID_CURRENCY_REGEX = /^\w{3,5}$/

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

def get_api_url(from, to, options = {})
  timestamp = options.fetch(:timestamp, nil)
  api_path = timestamp ? API_PATH_HISTORICAL : API_PATH_DEFAULT
  query_params = {
    fsym: to,
    tsyms: from.join(','),
    toTs: timestamp
  }.reject { |_, v| v.nil? }
  API_ROOT + api_path + "?" + URI.encode_www_form(query_params)
end

def get_conversions(from, to)
  url = get_api_url(from, to)
  resp = open(url).read
  data = JSON.parse(resp)
  conversions = data.map do |(symbol, price)|
    [symbol, 1/price]
  end
  Hash[conversions]
end

def get_exchange_currency
  (ARGV[0] || EXCHANGE_CURRENCY_DEFAULT).upcase
end

OptionParser.new do |parser|
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
    "--portfolio USER [CURRENCY]",
    "Display a user's portfolio"
  ) do |name|
    abort_on_invalid_username(name)

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
    conversions = get_conversions(symbols, exchange_currency)
    holdings = result.map do |(crypto, amount)|
      conversions[crypto] * amount
    end

    cryptos = holdings
      .zip(result)
      .map { |conversion, row| [conversion] + row }
      .sort_by { |(conversion)| -conversion }

    total = holdings.reduce(:+)

    puts [
      "USER: #{name}",
      "TOTAL: #{total.round(2)}",
      "\n"
    ].join("\n")

    headers = [
      "Percent",
      "Currency",
      "Price",
      "Holdings",
      "Value (#{exchange_currency})"
    ]
    format = format_headers(headers)
    puts format % headers

    cryptos.each do |(conversion, symbol, amount)|
      percent = (conversion / total * 100).to_i
      puts format % [
        "#{percent}%",
        symbol,
        (conversion / amount).round(2),
        amount.round(2),
        conversion.round(2)
      ]
    end
  end

  parser.on(
    "-l",
    "--leaderboard",
    "Display the current leaderboard",
  ) do
    db = SQLite3::Database.new(DB_FILE_NAME)

    exchange_currency = get_exchange_currency

    cryptos = db.execute2 <<-SQL
      SELECT symbol FROM cryptos
    SQL

    conversions = get_conversions(cryptos, exchange_currency)

    holdings = db.execute2(<<-SQL).drop(1)
      SELECT u.name, c.symbol, h.amount
      FROM holdings h
      LEFT OUTER JOIN cryptos c ON c.id = h.crypto_id
      LEFT OUTER JOIN users u ON u.id = h.user_id
    SQL

    users = holdings.group_by { |(name)| name }.to_a
    user_totals = users.map do |(user, value)|
      total = value.reduce(0) do |total, (_, crypto, amount)|
        total + (conversions[crypto] * amount)
      end
      [user, total]
    end
    sorted_user_totals = user_totals.sort_by { |(_, total)| -total }

    puts "LEADERBOARD\n\n"

    headers = [
      "Ranking",
      "User",
      "Total (#{exchange_currency})"
    ]
    format = format_headers(headers)
    puts format % headers

    sorted_user_totals.each_with_index do |(user, total), i|
      puts format % [
        i + 1,
        user,
        total.round(2)
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
end.parse!
