import pymysql
import os
import json

DB_HOST = os.environ['DB_HOST']
DB_PORT = int(os.environ.get('DB_PORT', '3306'))
DB_USER = os.environ['DB_USER']
DB_PASSWORD = os.environ['DB_PASSWORD']
DB_NAME = os.environ['DB_NAME']

def lambda_handler(event, context):
    action = event.get('action')
    params = event.get('params', [])
    
    conn = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        connect_timeout=5
    )
    
    try:
        with conn.cursor() as cursor:
            if action == 'INSERT':
                sql = 'INSERT INTO users (userId, username, plan, createdAt) VALUES (%s, %s, %s, %s)'
                cursor.execute(sql, params)
            elif action == 'DELETE':
                sql = 'DELETE FROM users WHERE userId = %s'
                cursor.execute(sql, params)
            else:
                raise ValueError(f'Unknown action: {action}')
        conn.commit()
        return {'statusCode': 200, 'body': f'{action} replicated successfully'}
    except Exception as e:
        print(f'Replication error: {str(e)}')
        raise
    finally:
        conn.close()
