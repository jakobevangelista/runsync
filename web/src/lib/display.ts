import type { PaceMode, Units } from "./contracts";

export function parseDisplaySearch(
  search: Record<string, unknown>,
  defaults: { defaultUnits: Units; defaultPace: PaceMode },
) {
  return {
    units:
      search.units === "metric" || search.units === "imperial"
        ? search.units
        : defaults.defaultUnits,
    pace:
      search.pace === "average" || search.pace === "rolling" ? search.pace : defaults.defaultPace,
  };
}
