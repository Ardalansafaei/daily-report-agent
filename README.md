# ایجنت گزارش روزانه

گزارش روزانه‌ی فعالیت QA من در مخزن `accommodation-qa`: اسناد بررسی‌شده، APIهای تست‌شده، ایشوهای ثبت‌شده و ایشوهای بررسی‌شده با وضعیتشان.

## فایل‌ها

| مسیر | کار |
|---|---|
| `AGENTS.md` | دستورهای ایجنت؛ از همین‌جا شروع می‌شود. |
| `docs/report-guide.md` | تعریف هر بخش، قاعده‌ی شمارش و محدودیت‌ها. |
| `config/report-config.json` | برچسب‌های فارسی و نشانه‌های تشخیص نوع کامنت. |
| `tools/daily-report.ps1` | جمع‌آوری گزارش روز و ذخیره‌ی آن در پایگاه محلی (فقط خواندن از گیت‌لب). |
| `tools/report_store.py` | نگهداری روزها و ساخت گزارش هفتگی یا ماهانه از پایگاه محلی. |

## استفاده

از این پوشه اجرا کن:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1 -Date 1405/08/12
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1 -Date 2026-10-20 -From 09:00 -To 18:00
```

مسیر گزارش روی ترمینال چاپ می‌شود و متن در `.tmp/daily-report/report-<date>.txt` ذخیره می‌شود. همان روز در `.data/reports.db` هم می‌ماند تا گزارش هفتگی و ماهانه بدون خواندن دوبارهٔ گیت‌لب ساخته شود.

## نکته‌های امنیتی

- فقط `GET`؛ هیچ کامنت، ایشو یا صفحه‌ای ساخته یا ویرایش نمی‌شود.
- همه‌ی تماس‌های گیت‌لب از راه `tools/gitlab.ps1` انجام می‌شود؛ `.env` خوانده یا چاپ نمی‌شود.
- هیچ فایلی از ایجنت اصلی QA و تسک‌هایش تغییر نمی‌کند.
