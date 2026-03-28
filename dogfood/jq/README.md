# jq

JSON query and transform tool (subset).

## usage

```
pyr run main.pyr <filter> <file>
```

## supported filters

- `.` - identity (pretty print)
- `.field` - field access
- `.field.nested` - nested field access
- `.arr[N]` - array index
- `.arr[N].field` - index then field access
- `.[]` - iterate array or object values
- `keys` - list object keys
- `length` - count elements
- `type` - value type name
- `filter | filter` - pipe filters

## test

```
pyr run main.pyr "." test.json
pyr run main.pyr ".company" test.json                          # "Acme Corp"
pyr run main.pyr ".founded" test.json                          # 1995
pyr run main.pyr ".ceo" test.json                              # null
pyr run main.pyr ".locations" test.json                        # ["Portland", "Austin", "Berlin"]
pyr run main.pyr ".locations[1]" test.json                     # "Austin"
pyr run main.pyr ".departments[0].lead.name" test.json         # "Dana Chen"
pyr run main.pyr ".departments[1].projects[0].name" test.json  # "Rebrand"
pyr run main.pyr ".locations | length" test.json               # 3
pyr run main.pyr ".locations[]" test.json                      # "Portland" "Austin" "Berlin"
pyr run main.pyr "keys" test.json                              # ["company", "founded", ...]
pyr run main.pyr ".metadata" test.json                         # {version, generated, schema}
```
