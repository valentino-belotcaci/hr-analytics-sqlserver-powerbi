USE [hr-data];
GO

/* =====================================================
   04_clean_data.sql
   Goal: create a cleaned copy of the employees data.
   - The raw table dbo.employees is NEVER modified.
   - Part A fixes only what is safe and obvious.
   - Part B creates views that LABEL and FLAG the remaining
     problems, without changing any value (HR must confirm those).
   ===================================================== */


/* ---------- PART A: cleaned table ---------- */


-- A2. Check that the duplicates are EXACT copies (all columns identical).
--     SELECT DISTINCT * removes rows that are identical in every column.
SELECT COUNT(*) AS employees_number
FROM (
    SELECT DISTINCT *
    FROM dbo.employees_clean
) AS t;
-- Expected: 400. If you get more, some duplicates differ in a field:
-- do NOT delete them, flag them instead.


-- A3. Delete the duplicate rows from the copy.
--     ROW_NUMBER() numbers the rows inside each EmployeeID (1, 2, ...).
--     We keep row 1 and delete the others.
--     The CTE ("numbered") is needed because WHERE cannot use row_num
--     in the same query that creates it.
WITH numbered AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY EmployeeID ORDER BY EmployeeID) AS row_num
    FROM dbo.employees_clean
)
DELETE FROM numbered
WHERE row_num > 1;
-- Expected: 6 rows deleted


-- A4. Fix the safe problems: extra spaces, last-name capitalization, gender codes.
--     LTRIM/RTRIM remove spaces on the left/right.
--     SQL Server has no PROPER(), so the capital letter is built with
--     UPPER(first letter) + LOWER(rest).
--     A blank last name becomes NULL (it stays missing: we don't invent data).
--     CASE WHEN works like Excel's IF: the first matching WHEN wins.
UPDATE dbo.employees_clean
SET FirstName = LTRIM(RTRIM(FirstName)),
    LastName  = CASE
                    WHEN LastName IS NULL OR LTRIM(RTRIM(LastName)) = '' THEN NULL
                    ELSE UPPER(LEFT(LTRIM(RTRIM(LastName)), 1))
                         + LOWER(SUBSTRING(LTRIM(RTRIM(LastName)), 2, 100))
                END,
    Gender    = CASE
                    WHEN UPPER(LTRIM(RTRIM(Gender))) IN ('M', 'MALE')   THEN 'M'
                    WHEN UPPER(LTRIM(RTRIM(Gender))) IN ('F', 'FEMALE') THEN 'F'
                    ELSE Gender
                END;


-- A5. Checks on the cleaned table.
SELECT COUNT(*) AS rows_clean FROM dbo.employees_clean;                  -- expected 400

SELECT Gender, COUNT(*) AS n
FROM dbo.employees_clean
GROUP BY Gender;                                                         -- only M and F

SELECT COUNT(*) AS name_problems                                         -- expected 0
FROM dbo.employees_clean
WHERE DATALENGTH(FirstName) <> DATALENGTH(LTRIM(RTRIM(FirstName)))
   OR LastName COLLATE Latin1_General_CS_AS = UPPER(LastName) COLLATE Latin1_General_CS_AS;

-- NOT fixed on purpose (only HR can answer): missing/invalid department,
-- salary, employment %, dates, birthdate, managers, duplicate email.
-- Re-run the checks from 03_data_quality_checks.sql on employees_clean:
-- duplicates, gender and name formatting should now be 0, the rest remain.
GO


/* ---------- PART B: views that flag the remaining problems ---------- */

-- B1. vw_employees_clean: adds a department name, validity flags (1 = ok, 0 = problem)
--     and a DataIssue text. No row is removed and no value is changed.
--     CREATE VIEW must be the first statement of its batch: that is why GO is above.
CREATE OR ALTER VIEW dbo.vw_employees_clean AS
WITH base AS (
    -- join the department name and look for the manager in the same table.
    -- COUNT(*) OVER (PARTITION BY Email) counts how many rows share each email
    -- (a window function: it does not collapse the rows like GROUP BY).
    SELECT e.*,
           d.DepartmentName,
           m.EmployeeID AS ManagerFound,
           COUNT(*) OVER (PARTITION BY e.Email) AS EmailCount
    FROM dbo.employees_clean AS e
    LEFT JOIN dbo.departments AS d
           ON e.DepartmentID = d.DepartmentID
    LEFT JOIN dbo.employees_clean AS m
           ON e.ManagerID = m.EmployeeID
),
flags AS (
    -- one flag per rule. The limits (500000, 10-100%) are our own assumptions:
    -- in a real job we would ask HR for the valid ranges.
    SELECT *,
        CASE WHEN DepartmentName IS NOT NULL THEN 1 ELSE 0 END AS IsValidDepartment,
        CASE WHEN Salary IS NULL OR Salary <= 0 OR Salary > 500000
             THEN 0 ELSE 1 END AS IsValidSalary,
        CASE WHEN EmploymentPct IS NULL OR EmploymentPct > 100 OR EmploymentPct < 10
             THEN 0 ELSE 1 END AS IsValidEmploymentPct,
        CASE WHEN TerminationDate < HireDate OR HireDate > GETDATE()
             THEN 0 ELSE 1 END AS IsValidDates,
        CASE WHEN BirthDate > DATEADD(year, -18, CAST(GETDATE() AS date))
             THEN 0 ELSE 1 END AS IsValidBirthDate,
        -- a blank ManagerID is valid (top of the hierarchy)
        CASE WHEN ManagerID IS NOT NULL AND (ManagerFound IS NULL OR ManagerID = EmployeeID)
             THEN 0 ELSE 1 END AS IsValidManager,
        CASE WHEN EmailCount > 1 THEN 0 ELSE 1 END AS IsUniqueEmail,
        CASE WHEN LastName IS NULL THEN 0 ELSE 1 END AS HasLastName
    FROM base
)
SELECT
    EmployeeID, FirstName, LastName, Gender, BirthDate, HireDate, TerminationDate,
    DepartmentID,
    ISNULL(DepartmentName, 'Unassigned') AS DepartmentName,   -- label for missing/invalid
    LocationID, ManagerID, JobTitle, Grade, EmploymentPct, Salary, Email,
    IsValidDepartment, IsValidSalary, IsValidEmploymentPct, IsValidDates,
    IsValidBirthDate, IsValidManager, IsUniqueEmail, HasLastName,
    -- DataIssue: all problems of the row in one text, like the Excel column.
    -- CONCAT_WS joins the texts with '; ' and skips the NULLs
    -- (a CASE without ELSE returns NULL when its condition is false).
    CONCAT_WS('; ',
        CASE WHEN DepartmentID IS NULL THEN 'Missing department' END,
        CASE WHEN DepartmentID IS NOT NULL AND IsValidDepartment = 0 THEN 'Invalid department ID' END,
        CASE WHEN IsValidSalary = 0 THEN 'Invalid salary' END,
        CASE WHEN IsValidEmploymentPct = 0 THEN 'Invalid employment %' END,
        CASE WHEN TerminationDate < HireDate THEN 'Termination before hire' END,
        CASE WHEN HireDate > GETDATE() THEN 'Hire date in future' END,
        CASE WHEN IsValidBirthDate = 0 THEN 'Under 18' END,
        CASE WHEN IsValidManager = 0 THEN 'Manager not found / self-manager' END,
        CASE WHEN IsUniqueEmail = 0 THEN 'Duplicate email' END,
        CASE WHEN HasLastName = 0 THEN 'Missing last name' END
    ) AS DataIssue
FROM flags;
GO


-- B2. vw_salary_history_clean: keeps only salary rows of employees that exist.
--     INNER JOIN drops the orphan rows (IDs 5555 and 6666).
--     The raw salary_history still contains them.
CREATE OR ALTER VIEW dbo.vw_salary_history_clean AS
SELECT sh.EmployeeID, sh.EffectiveDate, sh.Salary
FROM dbo.salary_history AS sh
INNER JOIN dbo.employees_clean AS e
        ON sh.EmployeeID = e.EmployeeID;
GO


-- B3. Checks on the views.
SELECT COUNT(*) AS rows_in_view FROM dbo.vw_employees_clean;           -- expected 400
SELECT COUNT(*) AS rows_in_view FROM dbo.vw_salary_history_clean;      -- expected 2410

-- employees with at least one issue
SELECT COUNT(*) AS employees_with_issues
FROM dbo.vw_employees_clean
WHERE DataIssue <> '';

-- which combinations of issues exist, and how many employees each
SELECT DataIssue, COUNT(*) AS n
FROM dbo.vw_employees_clean
WHERE DataIssue <> ''
GROUP BY DataIssue
ORDER BY n DESC;

-- headcount by department: "Unassigned" should be about 9
SELECT DepartmentName, COUNT(*) AS headcount
FROM dbo.vw_employees_clean
GROUP BY DepartmentName
ORDER BY headcount DESC;