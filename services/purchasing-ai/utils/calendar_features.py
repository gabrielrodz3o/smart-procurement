"""
Dominican Republic public holidays, seasonal events and climate helpers.
Holidays fetched live from https://date.nager.at/api/v3/PublicHolidays/{year}/DO
with in-memory cache per year (refreshed once per process lifetime).
"""

from datetime import date, timedelta
from typing import Optional
import httpx
import pandas as pd

# ── In-memory caches ────────────────────────────────────────────────────────
_holiday_cache: dict[int, set] = {}        # year → set[date]
_holiday_names: dict[int, dict] = {}       # year → {date: name_lower}

NAGER_URL = "https://date.nager.at/api/v3/PublicHolidays/{year}/DO"

SEMANA_SANTA_KEYWORDS = ("semana", "jueves", "viernes", "pascua", "santo", "santa", "good friday", "holy", "easter")


def _fetch_holidays_for_year(year: int) -> set:
    """Fetch public holidays for `year` from date.nager.at. Caches dates AND names."""
    if year in _holiday_cache:
        return _holiday_cache[year]
    try:
        resp = httpx.get(NAGER_URL.format(year=year), timeout=5.0)
        resp.raise_for_status()
        holidays: set = set()
        names: dict = {}
        for item in resp.json():
            try:
                d = date.fromisoformat(item["date"])
                holidays.add(d)
                names[d] = (item.get("localName", "") + " " + item.get("name", "")).lower()
            except Exception:
                pass
        _holiday_cache[year] = holidays
        _holiday_names[year] = names
        return holidays
    except Exception:
        _holiday_cache[year] = _fixed_fallback(year)
        _holiday_names[year] = {}
        return _holiday_cache[year]


def _fixed_fallback(year: int) -> set:
    fixed = [
        (1, 1), (1, 6), (1, 21), (1, 26), (2, 27), (5, 1),
        (8, 16), (9, 24), (11, 6), (12, 25),
    ]
    return {date(year, m, d) for m, d in fixed}


def _preload_years(years: list) -> None:
    for year in years:
        if year not in _holiday_cache:
            _fetch_holidays_for_year(year)


# ── Climate / rainy season windows ──────────────────────────────────────────
def is_rainy_season(d: date) -> bool:
    if d.month in (5, 6):           # Primera temporada lluviosa
        return True
    if d.month in (8, 9, 10, 11):   # Segunda temporada / huracanes
        return True
    return False


# ── Tourism peaks ────────────────────────────────────────────────────────────
def is_tourism_peak(d: date) -> bool:
    if d.month in (12, 1):      # Christmas / New Year
        return True
    if d.month in (6, 7, 8):    # Summer — North American / European tourists
        return True
    return False


# ── High demand ──────────────────────────────────────────────────────────────
def is_high_season(d: date) -> bool:
    if d.month == 12:
        return True
    if is_tourism_peak(d):
        return True
    holidays = _fetch_holidays_for_year(d.year)
    # High season during any public holiday week
    for delta in range(-3, 4):
        if d + timedelta(days=delta) in holidays:
            return True
    return False


def is_rd_holiday(d: date) -> Optional[str]:
    holidays = _fetch_holidays_for_year(d.year)
    return "holiday" if d in holidays else None


def is_semana_santa(d: date) -> bool:
    """True if date is a Semana Santa holiday per nager.at (uses cached names)."""
    holidays = _fetch_holidays_for_year(d.year)
    if d not in holidays:
        return False
    name = _holiday_names.get(d.year, {}).get(d, "")
    if any(kw in name for kw in SEMANA_SANTA_KEYWORDS):
        return True
    # Fallback: April 1–21
    return d.month == 4 and 1 <= d.day <= 21


def get_weekday_label(d: date) -> str:
    days_es = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"]
    return days_es[d.weekday()]


def is_weekend(d: date) -> bool:
    return d.weekday() >= 4


def days_until_next_holiday(d: date) -> int:
    for delta in range(1, 366):
        target = d + timedelta(days=delta)
        holidays = _fetch_holidays_for_year(target.year)
        if target in holidays:
            return delta
    return 365


# ── Prophet regressor builder ────────────────────────────────────────────────

def build_prophet_regressors(df_dates: pd.Series) -> pd.DataFrame:
    """
    Returns a DataFrame with RD-specific regressor columns for Prophet.
    Holidays are fetched live from date.nager.at (cached per year).

    Regressors:
      semana_santa       – Jueves/Viernes Santo / Easter (mobile, exact from API)
      tourism_peak       – Dec/Jan/Jun/Jul/Aug
      rainy_season       – May/Jun + Aug/Sep/Oct/Nov
      high_season        – combined flag
      dia_independencia  – 27 Feb
      dia_restauracion   – 16 Aug
      navidad            – 24–31 Dec
      anio_nuevo         – 1–3 Jan
      rd_holiday         – any public holiday from nager.at
    """
    dates = pd.to_datetime(df_dates).dt.date

    # Preload all years present in the date range
    years = list({d.year for d in dates})
    _preload_years(years)

    regs = pd.DataFrame(index=df_dates.index)
    regs["semana_santa"]      = dates.apply(lambda d: 1 if is_semana_santa(d) else 0)
    regs["tourism_peak"]      = dates.apply(lambda d: 1 if is_tourism_peak(d) else 0)
    regs["rainy_season"]      = dates.apply(lambda d: 1 if is_rainy_season(d) else 0)
    regs["high_season"]       = dates.apply(lambda d: 1 if is_high_season(d) else 0)
    regs["dia_independencia"] = dates.apply(lambda d: 1 if (d.month == 2 and d.day == 27) else 0)
    regs["dia_restauracion"]  = dates.apply(lambda d: 1 if (d.month == 8 and d.day == 16) else 0)
    regs["navidad"]           = dates.apply(lambda d: 1 if (d.month == 12 and d.day in range(24, 32)) else 0)
    regs["anio_nuevo"]        = dates.apply(lambda d: 1 if (d.month == 1  and d.day <= 3) else 0)
    regs["rd_holiday"]        = dates.apply(lambda d: 1 if is_rd_holiday(d) else 0)
    return regs
