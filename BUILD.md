# Gaming DNS — GitHub build

## استفاده

کل محتوای این پوشه را در ریشه Repository گیت‌هاب قرار بده و به branch `main` push کن.

Workflow زیر خودکار انجام می‌شود:

1. منابع عمومی DNS و Repositoryهای مرتبط با Gaming را جمع‌آوری می‌کند.
2. فایل `data/dns_database.json` را می‌سازد.
3. فایل دیتابیس را در همان Repository commit می‌کند.
4. Android project را با همان نسخه Flutter بازسازی می‌کند تا Gradle سازگار باشد.
5. `flutter pub get` و `flutter analyze` را اجرا می‌کند.
6. APK Release را می‌سازد.
7. APK را در GitHub Actions به عنوان Artifact قرار می‌دهد.

## اجرای دستی

در GitHub به مسیر **Actions → Gaming DNS - Update Database & Build APK** برو و **Run workflow** را بزن.

## APK

بعد از موفقیت Build:

**Actions → اجرای موفق → Artifacts → Gaming-DNS-Release-APK**

## دیتابیس

فایل زیر توسط GitHub Actions ساخته و مرتب به‌روزرسانی می‌شود:

`data/dns_database.json`

اپ هنگام Build با `DNS_DATABASE_URL` به همین فایل در branch `main` متصل می‌شود. اگر دیتابیس موقتاً در دسترس نباشد، اپ از منابع عمومی تعریف‌شده در کد استفاده می‌کند.

## نکته

هیچ برنامه‌ای نمی‌تواند «کل اینترنت» را crawl کند. این پروژه به‌جای آن از فهرست‌های عمومی DNS، منابع Gaming و جستجوی Repositoryهای GitHub استفاده می‌کند و نتیجه را در یک دیتابیس واحد نگه می‌دارد.
