const express = require('express')
const cors = require('cors')
const fs = require('fs')

const app = express()

// db config
const { Pool } = require('pg')

// certificate for rds
const useSsl = process.env.DB_SSL !== 'false' // default: true

const pool = new Pool({
  host: process.env.DB_HOST, // rds endpoint
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  port: process.env.DB_PORT ? Number(process.env.DB_PORT) : 5432,
  ssl: useSsl
    ? {
        rejectUnauthorized: true,
        ca: fs.readFileSync('./rds-ca.pem', 'utf8') // /app/rds-ca.pem
      }
    : false
})

// Ensure table exists at startup
async function initDb() {
  const createTableSql = `
    CREATE TABLE IF NOT EXISTS transactions (
      id         SERIAL PRIMARY KEY,
      name       TEXT    NOT NULL,
      balance    NUMERIC NOT NULL,
      outgoing   NUMERIC NOT NULL,
      incoming   NUMERIC NOT NULL,
      result     NUMERIC NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `
  try {
    await pool.query(createTableSql)
    console.log('DB init: transactions table is ready')
  } catch (err) {
    console.error('DB init error:', err)
  }
}

initDb()

// express server config
const FRONTEND_URL = process.env.FRONTEND_URL || ''

// Allow CloudFront domain
app.use(cors({
  origin: FRONTEND_URL
}))

// Provide api endpoint
app.get('/api/process_payment', async (req, res) => {
    const name = (req.query.name || '').trim()
    const balance = parseFloat(req.query.balance)
    const outgoing = parseFloat(req.query.outgoing)
    const incoming = parseFloat(req.query.incoming)
    if (!name || isNaN(balance) || isNaN(outgoing) || isNaN(incoming))
        return res.status(400).send({ 
            code: 400, 
            message: 'Invalid request. Parameters "balance", "outgoing" and "incoming" are required and must be numbers.' 
        })

    const result = balance - outgoing + incoming

    try {
        // store transaction in DB, including name
        await pool.query(
          'INSERT INTO transactions (name, balance, outgoing, incoming, result) VALUES ($1, $2, $3, $4, $5)',
          [name, balance, outgoing, incoming, result]
        )
    
        res.send({
          message: `API service reached succesfully. Result is ${result}`,
          result: result,
          name: name
        })
      } catch (err) {
        console.error('DB insert error:', err)
        res.status(500).send({
          code: 500,
          message: 'Internal server error while saving transaction.'
        })
      }
    })

// provide healthcheck endpoint
app.get('/health', (req, res) => res.send('OK'))

// ---- listen for requets ----
const PORT = process.env.PORT || 3000
app.listen(PORT, () => {
  console.log(`API listening on port ${PORT}`)
})