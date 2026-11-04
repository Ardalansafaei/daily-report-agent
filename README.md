# ایجنت گزارش روزانه

گزارش روزانه‌ی فعالیت QA من در مخزن `accommodation-qa`: اسناد بررسی‌شده، APIهای تست‌شده، ایشوهای ثبت‌شده و ایشوهای بررسی‌شده با وضعیتشان.

## فایل‌ها

| مسیر | کار |
|---|---|
| `AGENTS.md` | دستورهای ایجنت؛ از همین‌جا شروع می‌شود. |
| `docs/report-guide.md` | تعریف هر بخش، قاعده‌ی شمارش و محدودیت‌ها. |
| `config/report-config.json` | برچسب‌های فارسی و نشانه‌های تشخیص نوع کامنت. |
| `tools/daily-report.ps1` | جمع‌آوری و ساخت گزارش (فقط خواندن). |

## استفاده

اول `.env.example` را کنار همین فایل به `.env` کپی کن و `GITLAB_URL` و `GITLAB_TOKEN` و `HTTP_PROXY_URL` را پر کن. بعد از این پوشه اجرا کن:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1 -Date 1405/08/12
powershell -NoProfile -ExecutionPolicy Bypass -File tools\daily-report.ps1 -Date 2026-10-20 -From 09:00 -To 18:00
```

گزارش روی ترمینال چاپ می‌شود و در `.tmp/daily-report/report-<date>.md` هم ذخیره می‌شود.

## نکته‌های امنیتی

- فقط `GET`؛ هیچ کامنت، ایشو یا صفحه‌ای ساخته یا ویرایش نمی‌شود.
- همه‌ی تماس‌های گیت‌لب از راه `tools/gitlab.ps1` انجام می‌شود؛ `.env` خوانده یا چاپ نمی‌شود.
- هیچ فایلی از ایجنت اصلی QA و تسک‌هایش تغییر نمی‌کند.
