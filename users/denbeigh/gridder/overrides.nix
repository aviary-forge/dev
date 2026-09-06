{ members, ... }:
attrs: {
  meta = (attrs.meta or { }) // {
    owners = with members; [ denbeigh ];
  };
}
