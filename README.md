# lita-untappd

Lita handler to pull checkins from Untappd and announce them in a channel. You'll eventually be able to check in beers, too!

Please excuse the mess, this is still very much a work in progress.

## Configuration

Add these to your Lita config:
```
config.handlers.untappd.client_id = <Untappd API client ID>
config.handlers.untappd.client_secret = <your Untappd API client secret>
```

If you'd like your bot to announce beers as they are drinked, you can tell it a channel to do so in:

```
config.handlers.untappd.channel = '#lolbeer'
```

It'll hit the Untappd API to check for new checkins every 5 minutes. If you want to change that, you can set it with:
```
config.handlers.untappd.interval = <minutes>
```


## Usage
1. Identify yourself
2. Drink beer
3. Check beer in
4. Watch as your bot announces your alcoholism to the world

### Identify yourself
```
untappd identify <username>     - Associate yourself to an Untappd username
untappd forget                  - Have the bot forget who you are
```

### Miscellaneous
```
untappd fetch                   - Manually fetch checkins. Will be removed later to be nice 
                                  to the Untappd API
```

## License

[MIT](http://opensource.org/licenses/MIT)
