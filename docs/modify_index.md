If you want to run Elasticsearch locally on windows to test things out:

1. Install Docker Desktop
2. Install Git Bash for Windows
3. Open Git Bash
4. Run: `wsl -d docker-desktop`
5. Then run: `sysctl -w vm.max_map_count=262144`
6. Then run: `exit`
7. Then start a container: `docker run --env node.name=es1 --env cluster.name=docker-elasticsearch --env cluster.initial_master_nodes=es1 --env discovery.seed_hosts=es1 --env cluster.routing.allocation.disk.threshold_enabled=false --env bootstrap.memory_lock=true --env 'ES_JAVA_OPTS=-Xms1g -Xmx1g' --env xpack.security.enabled=false --env xpack.license.self_generated.type=trial --env http.port=9200 --env action.destructive_requires_name=false --ulimit nofile=65536:65536 --ulimit memlock=-1:-1 --publish 9200:9200 --detach --name=es1 docker.elastic.co/elasticsearch/elasticsearch:7.15.2`
