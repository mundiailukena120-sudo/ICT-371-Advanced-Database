# ICT371 Advanced Database - ILUKENA MUNDIA (202402030)

One self-contained PostgreSQL script per question. Each script drops and recreates its own objects, so it can be re-run.

| File | Question |
|---|---|
| Q1_pharmacy.sql | Pharmacy Stock and Daily Sales |
| Q2_fees.sql | University Fee Payments |
| Q3_library.sql | Library Returns and Overdue Fines |
| Q4_clinic.sql | Clinic Appointment Scheduling |
| Q5_hostel.sql | Hostel Room Allocation |
| Q6_payroll.sql | Monthly Payroll Processing |
| Q7_water.sql | Water Meter Readings and Billing |
| Q8_fleet.sql | Transport Fleet Maintenance |
| Q9_maize.sql | Farmer Cooperative Maize Deliveries |
| Q10_scholarship.sql | Scholarship Application Assessment |

Run with: `psql -d yourdb -f Q1_pharmacy.sql`

Scheduled jobs use the `pg_cron` extension (`CREATE EXTENSION pg_cron;`). pg_cron runs on the server's cron timezone (UTC by default). If it is not installed, the script prints the exact `cron.schedule(...)` command to run.
