graph LR
    subgraph Data Source
        Nginx[Nginx Access Log] -->|File Watch| VectorAgent(Vector Agent)
    end
    
    subgraph Message Queue
        VectorAgent -->|JSON| Kafka{Kafka Topic}
    end
    
    subgraph Data Processing & Storage
        Kafka -->|Consumer Group| VectorAgg(Vector Aggregator)
        VectorAgg -->|Batch Write| ClickHouse[(ClickHouse)]
    end
    
    subgraph Visualization
        ClickHouse -->|Query| Grafana[Grafana Dashboard]
    end
