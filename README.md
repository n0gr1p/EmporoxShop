# EmporoxShop

Windower addon for bulk purchasing items from Emporox.

## Installation

Place the EmporoxShop folder in your Windower addons directory, then load it:

```text
//lua l EmporoxShop
```

## Usage

Stand near Emporox and run:

```text
//emps buy Ghastly Stone 200
```

EmporoxShop will open Emporox.

Navigate to the requested item and purchase one manually. After that first purchase is detected, the addon will continue buying the remaining quantity automatically.

## Commands

```text
//emps buy <item name> <quantity>
//emps status
//emps stop
//emps help
```

Example:

```text
//emps buy Ghastly Stone 200
```

Use `//emps stop` at any time to cancel the current purchase run.

## Notes

- You must be near Emporox before starting.
- The first item must be purchased manually.
- If a purchase does not complete as expected, the addon stops instead of continuing.
