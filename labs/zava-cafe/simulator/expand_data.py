"""One-time script to expand Products table to ~2M rows for demo."""
import pymssql, time

conn = pymssql.connect(
    server='sql-zava.database.windows.net',
    user='<SQL_ADMIN_USER>',
    password='<SQL_PASSWORD>',
    database='sqldb-zava',
    login_timeout=10,
    timeout=300,
)
cur = conn.cursor()

cur.execute('SELECT COUNT(*) FROM Products')
current = cur.fetchone()[0]
print(f'Current rows: {current:,}')

target = 2_000_000
if current >= target:
    print('Already at target. Done.')
    conn.close()
    exit()

needed = target - current
print(f'Need to insert {needed:,} more rows...')

batch_size = 50_000
num_cats = 50
inserted = 0
cat_idx = 1
start = time.time()

while inserted < needed:
    batch = min(batch_size, needed - inserted)
    cat_label = f'Filler_{cat_idx:03d}'
    sql = (
        f"INSERT INTO Products (Name, Category, Price) "
        f"SELECT TOP {batch} "
        f"'P-' + CAST(ABS(CHECKSUM(NEWID())) AS VARCHAR(10)), "
        f"'{cat_label}', "
        f"CAST(RAND(CHECKSUM(NEWID())) * 490 + 10 AS DECIMAL(10,2)) "
        f"FROM sys.all_objects a CROSS JOIN sys.all_objects b"
    )
    cur.execute(sql)
    conn.commit()
    inserted += batch
    cat_idx = (cat_idx % num_cats) + 1
    elapsed = time.time() - start
    pct = inserted / needed * 100
    rate = inserted / max(elapsed, 1)
    eta = (needed - inserted) / max(rate, 1)
    print(f'  {pct:.0f}% | {current + inserted:,} rows | {rate:.0f} rows/sec | ETA {eta:.0f}s')

cur.execute('SELECT COUNT(*) FROM Products')
final = cur.fetchone()[0]
print(f'\nDone! Final count: {final:,} rows in {time.time()-start:.0f}s')
conn.close()
