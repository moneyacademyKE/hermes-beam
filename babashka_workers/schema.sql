CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(100));
CREATE TABLE orders (order_id INT, user_id INT, amount DECIMAL(10, 2));
CREATE TABLE products (product_id INT PRIMARY KEY, product_name VARCHAR(100));
CREATE TABLE inventory (product_id INT, stock INT);