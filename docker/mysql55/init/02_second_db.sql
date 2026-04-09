CREATE DATABASE IF NOT EXISTS testdb2;
USE testdb2;

CREATE TABLE IF NOT EXISTS categories (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    sort_order INT DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    category_id INT NOT NULL,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (category_id) REFERENCES categories(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO categories (name, sort_order) VALUES
    ('Electronics', 1),
    ('Books', 2),
    ('Clothing', 3);

INSERT INTO items (category_id, title, description) VALUES
    (1, 'Smartphone', 'Latest model smartphone'),
    (1, 'Tablet', '10 inch tablet'),
    (2, 'Novel', 'Best selling novel'),
    (2, 'Textbook', 'Programming textbook'),
    (3, 'T-Shirt', 'Cotton t-shirt'),
    (3, 'Jacket', 'Winter jacket');
