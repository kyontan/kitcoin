# Kitcoin

## Initial setup

add genesis block into db

```
require "redis"

r = Redis.new
h = "000e2ed804af26fd0c2a95984b9aa38aabafc9d963a6c1ea5acb18390b079ad3"
r.set("#{h}:prev","")
r.set("#{h}:nonce","NCCMMANCCMCCMCCMCCMMAMMANCC")
r.set("#{h}:miner","kyontan")
r.set("#{h}:msg","Genesis block!")
r.set("#{h}:datetime", "2017-12-26T18:36:32+00:00")
r.set("difficulty", 2)
r.set("transfer_charge", 0.1)
```
