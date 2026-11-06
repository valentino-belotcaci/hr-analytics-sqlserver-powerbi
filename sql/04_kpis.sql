USE [hr-data]
GO

/* =====================================================
   05_kpis.sql
   Goal: HR KPIs, all read from dbo.vw_employees_clean.
   Rules used everywhere:
   - "Active" = no termination date, or a termination date in the future,
     AND already hired (HireDate <= today).
   - Invalid values are excluded ONLY from the calculation they would distort
     (flags: IsValidSalary, IsValidEmploymentPct, IsValidDates).
   - Employees with a missing/invalid department appear as 'Unassigned'.
   ===================================================== */


-- 1. Headcount by department (active employees only).
SELECT DepartmentName AS Department,
       COUNT(*)       AS total_employees
FROM dbo.vw_employees_clean
WHERE (TerminationDate IS NULL OR TerminationDate > GETDATE())
  AND HireDate <= GETDATE()
GROUP BY DepartmentName
ORDER BY total_employees DESC;


-- 1b. Check: the department rows must add up to the number of active employees.
SELECT SUM(total_employees) AS sum_of_departments,
       (SELECT COUNT(*) FROM dbo.vw_employees_clean
        WHERE (TerminationDate IS NULL OR TerminationDate > GETDATE())
          AND HireDate <= GETDATE()) AS active_employees   -- both numbers must be equal
FROM (
    SELECT COUNT(*) AS total_employees
    FROM dbo.vw_employees_clean
    WHERE (TerminationDate IS NULL OR TerminationDate > GETDATE())
      AND HireDate <= GETDATE()
    GROUP BY DepartmentName
) AS t;


-- 2. Headcount and FTE by department (active employees only).
--    FTE = sum of employment percentages / 100.
--    100.0 (not 100) avoids integer division, which would drop the decimals.
--    The CASE ignores invalid percentages (>100 or <10), which would inflate the FTE.
--    Without ELSE, the CASE returns NULL and SUM skips those rows.
SELECT DepartmentName AS Department,
       COUNT(*) AS total_employees,
       SUM(CASE WHEN IsValidEmploymentPct = 1 THEN EmploymentPct END) / 100.0 AS FTE,
       SUM(CASE WHEN IsValidEmploymentPct = 0 THEN 1 ELSE 0 END)              AS excluded_invalid_pct
FROM dbo.vw_employees_clean
WHERE (TerminationDate IS NULL OR TerminationDate > GETDATE())
  AND HireDate <= GETDATE()
GROUP BY DepartmentName
ORDER BY total_employees DESC;


-- 3. Employees who left, per year.
--    Only rows that have a termination date (the NULLs are active employees),
--    already in the past, and with consistent dates.
SELECT YEAR(TerminationDate) AS termination_year,
       COUNT(*)              AS employees_that_left
FROM dbo.vw_employees_clean
WHERE TerminationDate IS NOT NULL
  AND TerminationDate <= GETDATE()
  AND IsValidDates = 1
GROUP BY YEAR(TerminationDate)
ORDER BY termination_year DESC;


-- 4. Turnover rate per year.
--    turnover % = terminations in the year / average headcount * 100
--    average headcount = (headcount on Jan 1 + headcount on Dec 31) / 2
--    The recursive CTE "Years" generates one row per year, from the first hire year
--    up to the current year. Employees with inconsistent dates are excluded.
--    NOTE: the current year is not complete, so its rate is year-to-date
--    and not comparable with the full years.
WITH Years AS (
    SELECT MIN(YEAR(HireDate)) AS calendar_year
    FROM dbo.vw_employees_clean
    WHERE IsValidDates = 1
    UNION ALL
    SELECT calendar_year + 1
    FROM Years
    WHERE calendar_year < YEAR(GETDATE())
),
YearlyMetrics AS (
    SELECT
        y.calendar_year,

        -- employed on Jan 1st
        SUM(CASE
            WHEN e.HireDate <= DATEFROMPARTS(y.calendar_year, 1, 1)
             AND (e.TerminationDate IS NULL OR e.TerminationDate >= DATEFROMPARTS(y.calendar_year, 1, 1))
            THEN 1 ELSE 0
        END) AS start_headcount,

        -- employed at the end of Dec 31st
        -- (someone terminated ON Dec 31 counts as a termination, not as active)
        SUM(CASE
            WHEN e.HireDate <= DATEFROMPARTS(y.calendar_year, 12, 31)
             AND (e.TerminationDate IS NULL OR e.TerminationDate > DATEFROMPARTS(y.calendar_year, 12, 31))
            THEN 1 ELSE 0
        END) AS end_headcount,

        -- terminated during this calendar year
        SUM(CASE
            WHEN YEAR(e.TerminationDate) = y.calendar_year
            THEN 1 ELSE 0
        END) AS terminations

    FROM Years AS y
    LEFT JOIN dbo.vw_employees_clean AS e
           ON e.IsValidDates = 1
          -- only employees whose employment touches this year
          AND e.HireDate <= DATEFROMPARTS(y.calendar_year, 12, 31)
          AND (e.TerminationDate IS NULL OR e.TerminationDate >= DATEFROMPARTS(y.calendar_year, 1, 1))
    GROUP BY y.calendar_year
)
SELECT
    calendar_year,
    start_headcount,
    end_headcount,
    terminations,
    CAST((start_headcount + end_headcount) / 2.0 AS DECIMAL(7,2)) AS avg_headcount,
    -- guard against division by zero
    CASE
        WHEN (start_headcount + end_headcount) = 0 THEN 0.00
        ELSE CAST(terminations * 100.0 / ((start_headcount + end_headcount) / 2.0) AS DECIMAL(5,2))
    END AS turnover_rate_pct
FROM YearlyMetrics
ORDER BY calendar_year DESC
OPTION (MAXRECURSION 100);


-- 5. Average tenure in years, for active employees and for employees who left.
--    Tenure runs from HireDate to the termination date (or today if still active).
--    Employees with inconsistent dates are excluded (they would give negative tenure).
--    365.25 converts days to years (decimal division, so no truncation).
WITH tenure AS (
    SELECT
        CASE WHEN TerminationDate IS NULL OR TerminationDate > GETDATE()
             THEN 'Active' ELSE 'Left' END AS status,
        DATEDIFF(day, HireDate,
                 CASE WHEN TerminationDate IS NULL OR TerminationDate > GETDATE()
                      THEN CAST(GETDATE() AS date) ELSE TerminationDate END) / 365.25 AS tenure_years
    FROM dbo.vw_employees_clean
    WHERE IsValidDates = 1
)
SELECT status,
       COUNT(*) AS employees,
       CAST(AVG(tenure_years) AS DECIMAL(5,2)) AS avg_tenure_years
FROM tenure
GROUP BY status;


-- 6. Gender split by grade (active employees only).
--    pct_in_grade: share of each gender inside its grade.
--    SUM(COUNT(*)) OVER (PARTITION BY Grade) = total of the grade
--    (a window function applied on top of the GROUP BY result).
SELECT Grade,
       Gender,
       COUNT(*) AS gender_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY Grade) AS DECIMAL(5,1)) AS pct_in_grade
FROM dbo.vw_employees_clean
WHERE (TerminationDate IS NULL OR TerminationDate > GETDATE())
  AND HireDate <= GETDATE()
GROUP BY Grade, Gender
ORDER BY Grade, Gender;


-- 7. Average salary by department (active employees, valid salaries only).
--    employees_used shows how many people the average is based on.
SELECT DepartmentName,
       COUNT(*) AS employees_used,
       CEILING(AVG(Salary)) AS avg_salary_department
FROM dbo.vw_employees_clean
WHERE IsValidSalary = 1
  AND (TerminationDate IS NULL OR TerminationDate > GETDATE())
  AND HireDate <= GETDATE()
GROUP BY DepartmentName
ORDER BY avg_salary_department DESC;


-- 8. Average salary by grade (same filters as query 7).
SELECT Grade,
       COUNT(*) AS employees_used,
       CEILING(AVG(Salary)) AS avg_salary_grade
FROM dbo.vw_employees_clean
WHERE IsValidSalary = 1
  AND (TerminationDate IS NULL OR TerminationDate > GETDATE())
  AND HireDate <= GETDATE()
GROUP BY Grade
ORDER BY avg_salary_grade DESC;


-- 9. Salary outliers inside each grade (z-score).
--    z-score = (salary - average of the grade) / standard deviation of the grade
--    = how many standard deviations the salary is from its grade's average.
--    Window functions (OVER PARTITION BY Grade) add the grade's average and
--    standard deviation to every row WITHOUT collapsing the rows.
--    Invalid salaries are excluded BEFORE computing the statistics,
--    otherwise they would distort the average and the standard deviation.
--    Threshold: |z| > 1 is our own, quite low, choice. Usual values are 2 or 3.
--    NULLIF avoids a division by zero if all salaries of a grade are equal.
WITH Z_scores AS (
    SELECT EmployeeID,
           Grade,
           Salary,
           AVG(Salary) OVER (PARTITION BY Grade) AS average_salary,
           (Salary - AVG(Salary) OVER (PARTITION BY Grade))
               / NULLIF(STDEV(Salary) OVER (PARTITION BY Grade), 0) AS z_score
    FROM dbo.vw_employees_clean
    WHERE IsValidSalary = 1
      AND (TerminationDate IS NULL OR TerminationDate > GETDATE())
      AND HireDate <= GETDATE()
)
SELECT EmployeeID,
       Grade,
       Salary,
       CAST(average_salary AS DECIMAL(10,0)) AS average_salary,
       CAST(z_score AS DECIMAL(5,2))         AS z_score
FROM Z_scores
WHERE ABS(z_score) > 1          -- both unusually high and unusually low salaries
ORDER BY ABS(z_score) DESC;