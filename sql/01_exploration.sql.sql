USE [hr-data]
GO
/* =====================================================
   02_exploration.sql
   Goal: explore the raw HR data before cleaning it.
   Note: the raw tables still contain the planted errors.
   ===================================================== */


-- 1. Duplicate check: total rows vs. distinct employees.
--    The difference shows how many duplicate rows exist.
SELECT COUNT(*)                     AS total_rows,
       COUNT(DISTINCT EmployeeID)   AS distinct_employees,
       COUNT(*) - COUNT(DISTINCT EmployeeID) AS duplicate_rows
FROM dbo.employees;
-- Expected: 406 rows, 400 distinct, 6 duplicates


-- 2. Which EmployeeIDs appear more than once.
SELECT EmployeeID, COUNT(*) AS times_present
FROM dbo.employees
GROUP BY EmployeeID
HAVING COUNT(*) > 1
ORDER BY EmployeeID;
-- Expected: 6 rows


-- 3. Active employees: the total that the city and country
--    queries (6 and 7) should add up to.
--    Active = no termination date, or a termination date in the future.
SELECT COUNT(*) AS active_employees
FROM dbo.employees
WHERE TerminationDate > GETDATE() OR TerminationDate IS NULL;


-- 4. Employees with no valid location. They would disappear
--    from an INNER JOIN, so this should be 0.
SELECT COUNT(*) AS employees_without_valid_location
FROM dbo.employees AS e
LEFT JOIN dbo.locations AS l
    ON e.LocationID = l.LocationID
WHERE l.LocationID IS NULL;
-- Expected: 0


-- 5. Employees with a blank or invalid department (NULL or ID 99).
--    Compare with the "Unassigned" count in the Excel pivot.
SELECT COUNT(*) AS employees_without_valid_department
FROM dbo.employees AS e
LEFT JOIN dbo.departments AS d
    ON e.DepartmentID = d.DepartmentID
WHERE d.DepartmentID IS NULL;
-- Expected: 9


-- 6. Headcount by department, all employees (including the duplicates
--    and the employees who have left).
--    LEFT JOIN keeps employees whose department is missing or invalid:
--    they appear as a row with department = NULL.
SELECT d.DepartmentName AS department, COUNT(*) AS employees_number
FROM [dbo].[employees] AS e
LEFT JOIN [dbo].[departments] AS d
    ON e.DepartmentID = d.DepartmentID
GROUP BY d.DepartmentName
ORDER BY employees_number DESC;


-- 6b. Check: the department rows must add up to the table total.
SELECT SUM(employees_number) AS sum_of_departments   -- expected: 406
FROM (
    SELECT COUNT(*) AS employees_number
    FROM [dbo].[employees] AS e
    LEFT JOIN [dbo].[departments] AS d
        ON e.DepartmentID = d.DepartmentID
    GROUP BY d.DepartmentName
) AS t;


-- 7. Headcount by city, active employees only.
SELECT l.City AS city, COUNT(*) AS employee_number
FROM [dbo].[employees] AS e
JOIN [dbo].[locations] AS l
    ON e.LocationID = l.LocationID
WHERE e.TerminationDate > GETDATE() OR e.TerminationDate IS NULL
GROUP BY l.City
ORDER BY employee_number DESC;


-- 8. Headcount by country, active employees only.
SELECT l.Country AS country, COUNT(*) AS employee_number
FROM [dbo].[employees] AS e
JOIN [dbo].[locations] AS l
    ON e.LocationID = l.LocationID
WHERE e.TerminationDate > GETDATE() OR e.TerminationDate IS NULL
GROUP BY l.Country
ORDER BY employee_number DESC;


-- 8b. Check: the city and country totals must both equal
--     the active employees from query 3.
SELECT
    (SELECT COUNT(*) FROM [dbo].[employees] AS e
     JOIN [dbo].[locations] AS l ON e.LocationID = l.LocationID
     WHERE e.TerminationDate > GETDATE() OR e.TerminationDate IS NULL) AS active_with_valid_location,
    (SELECT COUNT(*) FROM dbo.employees
     WHERE TerminationDate > GETDATE() OR TerminationDate IS NULL)     AS active_employees;
-- Expected: both numbers are equal