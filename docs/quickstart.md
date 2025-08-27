````markdown
## Quickstart (WSL2 + Docker Desktop)

1. Start Docker Desktop and enable WSL2 integration.  
2. Clone this repo and `cd wsl-ml-stack/`.  
3. Launch the stack:  
   ```bash
   make up
````

4. Open the UIs:

   * MinIO: [http://localhost:9001](http://localhost:9001) (use `.env` login)
   * Jupyter (PySpark): [http://localhost:8888](http://localhost:8888)
   * Spark Master: [http://localhost:8080](http://localhost:8080)
   * Airflow: [http://localhost:8085](http://localhost:8085) (admin/admin)
   * Ray Dashboard: [http://localhost:8265](http://localhost:8265)

5. Test the pipeline:

   ```bash
   make kafka-topic
   docker compose exec -T kafka \
     kafka-console-producer.sh --bootstrap-server kafka:9092 --topic events \
     <<< '{"message":"hello"}'
   ```

6. In Airflow, unpause & trigger `example_kafka_to_delta` to stream into Delta on MinIO.

```
