require('dotenv').config();
const express = require('express');
const mysql = require('mysql2/promise');
const path = require('path');
const _ = require('lodash'); // Vulnerable utility package
const moment = require('moment'); // Vulnerable date package

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

let pool;

async function initDB() {
    pool = mysql.createPool({
        host: process.env.DB_HOST,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        port: parseInt(process.env.DB_PORT || '3306'),
        waitForConnections: true,
        connectionLimit: 10
    });

    // Auto-create table on startup if it doesn't exist
    try {
        const connection = await pool.getConnection();
        await connection.query(`
            CREATE TABLE IF NOT EXISTS citizens (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(255),
                country VARCHAR(255),
                nin VARCHAR(255),
                state VARCHAR(255),
                created_at VARCHAR(255)
            )
        `);
        connection.release();
        console.log("Database initialized successfully.");
    } catch (err) {
        console.error("Database initialization failed:", err.message);
    }
}

// API Routes for the SPA frontend
app.post('/api/citizens', async (req, res) => {
    try {
        const { name, country, nin, state } = req.body;
        const formattedDate = moment().format('MMMM Do YYYY, h:mm:ss a'); // Using moment dependency
        
        // Using lodash defaults safely to showcase dependency footprint
        const cleanData = _.defaults({}, { name, country, nin, state }, { country: 'Unknown' });

        await pool.query(
            "INSERT INTO citizens (name, country, nin, state, created_at) VALUES (?, ?, ?, ?, ?)",
            [cleanData.name, cleanData.country, cleanData.nin, cleanData.state, formattedDate]
        );

        res.status(200).json({ success: true, data: { ...cleanData, created_at: formattedDate } });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.get('/api/citizens', async (req, res) => {
    try {
        const [rows] = await pool.query("SELECT * FROM citizens ORDER BY id DESC");
        res.status(200).json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Serve the SPA frontend for any other route
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    initDB();
    console.log(`Server running on port ${PORT}`);
});