-- Executado apenas na primeira inicialização do volume do PostgreSQL.
-- O banco "flash_sales" é criado via POSTGRES_DB; aqui criamos o segundo.
SELECT 'CREATE DATABASE contracts_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'contracts_db')\gexec
