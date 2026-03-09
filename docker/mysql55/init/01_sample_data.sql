CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    status ENUM('active', 'inactive') DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS products (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS orders (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL DEFAULT 1,
    total_price DECIMAL(10, 2) NOT NULL,
    ordered_at DATETIME NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (product_id) REFERENCES products(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO users (name, email, status) VALUES
    ('Taro Yamada', 'taro@example.com', 'active'),
    ('Hanako Suzuki', 'hanako@example.com', 'active'),
    ('Jiro Tanaka', 'jiro@example.com', 'inactive'),
    ('Yuki Sato', 'yuki@example.com', 'active'),
    ('Ken Takahashi', 'ken@example.com', 'active'),
    ('Miki Ito', 'miki@example.com', 'inactive'),
    ('Ryo Watanabe', 'ryo@example.com', 'active'),
    ('Aya Nakamura', 'aya@example.com', 'active'),
    ('Shin Kobayashi', 'shin@example.com', 'active'),
    ('Mai Yoshida', 'mai@example.com', 'inactive');

INSERT INTO products (name, price, stock) VALUES
    ('Laptop', 89800.00, 50),
    ('Keyboard', 4980.00, 200),
    ('Mouse', 2980.00, 300),
    ('Monitor', 34800.00, 80),
    ('USB Cable', 980.00, 500),
    ('Headphones', 12800.00, 120),
    ('Webcam', 6980.00, 90),
    ('SSD 1TB', 9800.00, 150);

INSERT INTO orders (user_id, product_id, quantity, total_price, ordered_at) VALUES
    (1, 1, 1, 89800.00, '2025-01-15 10:30:00'),
    (1, 2, 2, 9960.00, '2025-01-15 10:30:00'),
    (2, 3, 1, 2980.00, '2025-01-20 14:00:00'),
    (3, 4, 1, 34800.00, '2025-02-01 09:00:00'),
    (4, 5, 3, 2940.00, '2025-02-10 16:45:00'),
    (5, 6, 1, 12800.00, '2025-02-15 11:20:00'),
    (6, 7, 2, 13960.00, '2025-03-01 08:00:00'),
    (7, 8, 1, 9800.00, '2025-03-05 13:30:00'),
    (2, 1, 1, 89800.00, '2025-03-10 10:00:00'),
    (8, 2, 1, 4980.00, '2025-03-12 15:00:00'),
    (9, 3, 5, 14900.00, '2025-03-15 09:30:00'),
    (10, 4, 1, 34800.00, '2025-03-20 12:00:00');
