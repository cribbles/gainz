# gainz - a simple CLI cryptocurrency portfolio

## Summary

This is a script to keep track of the money you and your friends have lost gambling on cryptocurrencies.

## Usage

```bash
Usage: gainz.rb [options]
   -a, --add USER                   Add a user
   -u, --update USER CRYPTO AMOUNT  Update a user's crypto balance
   -p USER [-c, --currency CURRENCY] [-d, --duration DURATION],
       --portfolio                  Display a user's portfolio
   -l [-c, --currency CURRENCY] [-d, --duration DURATION],
       --leaderboard                Display the current leaderboard
   -h, --help                       Show this help message
```

## Dependencies

You probably already have everything you need installed.

- Ruby >= 1.9.3
- Sqlite3

## Setup

```bash
./init.sh
bundle install
```

## Key Features

- Fast and simple
- Multiple user support
- Everything is stored locally
- Tracks your portfolio in any major currency or cryptocurrency (defaults to USD)
- Shows % change over arbitrary durations - find out how much more your portfolio would have been worth an hour, day, week, month or year ago

## What this script does not do

- Encrypt your portfolio
- Help you make better investments
- Keep track of what you bought, when. The % change feature just tells you how much your portfolio would have been worth per coin at a given duration.

## Examples

### Creating a user

```bash
$ ./gainz.rb -a alice
Added user successfully.
```

### Updating a user's balance

```bash
$ ./gainz.rb -u alice eth 9.4
Updated balance successfully.

$ ./gainz.rb -u alice xmr 1.2
Updated balance successfully.

$ ./gainz.rb -u alice xlm 23.95
Updated balance successfully.
```

### Viewing a user's portfolio

```bash
$ ./gainz.rb -p alice
USER: alice
TOTAL: 1935.14 (-1.83%)

Percent      Currency      Price      Change      Holdings      Value (USD)
93%          ETH           192.09     (-1.88%)    9.40          1805.61
6%           XMR           104.21     (-1.03%)    1.20          125.05
0%           XLM           0.19       (-1.87%)    23.95         4.48
```

### Checking the leaderboard

```bash
$ ./gainz.rb -a bob
Added user successfully.

$ ./gainz.rb -u bob btc 3.22
Updated balance successfully.

$ ./gainz.rb -u bob bch 1.44
Updated balance successfully.

$ ./gainz.rb -u bob ltc 6
Updated balance successfully.

$ ./gainz.rb -l -d month -c eur
LEADERBOARD

Ranking      User      Total (EUR)      Change
1            bob       18243.16         (+0.54%)
2            alice     1669.61          (-37.18%)
```

## FAQ

**How do I update the amount of a currency I've already added?**

Just run `-u USER CURRENCY AMOUNT` with the new amount to overwrite it.

**How do I delete a user?**

There isn't a command for this. Just run a DELETE query from sqlite3 CLI:

```sql
DELETE FROM users WHERE name = '$NAME'
```

**Where does the price data come from?**

[CryptoCompare.com's API](https://www.cryptocompare.com/api/).

## TODO

- Add tests
- Put functions in different folders, or something like that?
- Move away from [`OptionParser`](https://ruby-doc.org/stdlib-1.9.3/libdoc/optparse/rdoc/OptionParser.html). Seemed like a good idea at the time, but it doesn't handle flag arguments well. Oops

## Contributing

Please keep changes Ruby 1.9.3 compatible. I like the syntax in later versions better too but I'm running this on a remote server using Ubuntu 14.04 LTS and don't want to tinker with rvm.

Special thanks [guregu](https://github.com/guregu) for tweaking the price conversion logic from O(N) to O(1).

## License

MIT
