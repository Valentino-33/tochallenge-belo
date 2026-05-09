ya se esta ejecutando el make tf-plan de la fase 1, mientras tanto quiero que revisemos lo siguiente:



Veo un error en el roadmap en la fase 4:



## Fase 4 — Apps (webserver-api01 y webserver-api02)

Salida: dos Helm charts publicados con las apps en Python, sus Dockerfiles,
y la carpeta `loadtest/` con los k6 scripts asociados a cada estrategia.

El código vive en los repos
[webserver-api01](https://github.com/Valentino-33/webserver-api01) y
[webserver-api02](https://github.com/Valentino-33/webserver-api02).

Estructura de cada repo:

```
webserver-apiNN/
├── Dockerfile
├── pyproject.toml          # FastAPI + uvicorn + structlog + prometheus_client
├── app/
│   ├── main.py             # endpoints /, /health, /version, /metrics
│   ├── logging_config.py   # 5 levels (info, debug, error, warn, trace)
│   └── ...
├── chart/                  # Helm chart de la app
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── rollout.yaml    # Rollout de ArgoCD (NO Deployment)
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── servicemonitor.yaml
│       └── hpa.yaml
├── loadtest/
│   ├── smoke.js
│   ├── load-bluegreen.js   # solo en api01
│   ├── load-canary.js      # solo en api02
│   └── README.md
└── .tekton/
    └── pipelinerun.yaml    # template del PipelineRun que dispara Tekton
```

El concepto que busco es: 



1 ) Repositorio de codigo por apis, codigo de la propia api/webserver+ loadtest y sus scripts en k6.



2) Repositorio donde se alojen todos los archivos de helm con esta estructura:

carpeta: pythonapps (Helm Chart Maestro para apps python) contiene: values.yaml, Chart.yaml y carpeta con templates, esta carpeta es un modelo, en un futuro se agregaria "javaapps", para poder usar diferentes charts.



Dentro de la carpeta de chart pythonapps:

carpeta: $appexample/webserver-api1 -> values-$appname.yaml (Va a contener las "keys", para la compilacion de cada appp como: registry, repo_url:, image_name:. Los datos necesarios para pushear al registry, indicar cual es el nombre/tag de la imagen, ejemplo image_name: webserverapi01 )



En el directorio raiz: 

carpeta: $appname/webserver-api1 -> values.yaml (default para que funcionen los templates), chart.yaml (idem a values) -> values-$envs.yaml (Template de helm para la app pytnon en este caso, en cada values se van a administrar los recursos de las apps por ambientes, y todo la infor que necesiten los templates para levantar esa app.)



Para este repositorio vamos a usar:

https://github.com/Valentino-33/belo-helm-charts.git



La idea es centralizar todo lo relacionado a helm, en un solo repositorio.