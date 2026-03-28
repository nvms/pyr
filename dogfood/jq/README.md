# jq

JSON query and transform tool (subset).

## usage

```
pyr run dogfood/jq/main.pyr -- <filter> <file>
```

## supported filters

- `.` - identity (pretty print)
- `.field` - field access
- `.field.nested` - nested field access
- `.arr[N]` - array index
- `.[]` - iterate array or object values
- `keys` - list object keys
- `length` - count elements
- `type` - value type name
- `filter | filter` - pipe filters
