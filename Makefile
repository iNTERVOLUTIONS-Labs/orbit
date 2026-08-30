# make usa /bin/sh, que en Ubuntu es dash y no entiende 'pipefail'. Sin esto,
# 'test-strict' muere con "Illegal option -o pipefail" y el fallo parece de las
# pruebas cuando es del intérprete.
SHELL := /bin/bash

.PHONY: help check lint test test-strict install

help:
	@echo "make check        Sintaxis de los scripts"
	@echo "make lint         shellcheck (debe salir limpio)"
	@echo "make test         Sintaxis + lint + todas las pruebas"
	@echo "make test-strict  Igual, pero falla si alguna suite se ha saltado"
	@echo "make install      Instalar en este equipo (necesita root)"

check:
	bash -n orbit
	bash -n install.sh
	bash -n tests/lib.sh
	@echo "OK sintaxis"
	@# Una suite que existe y no ejecuta nadie es la peor forma del verde que
	@# miente: 'provision_test.sh' llevaba desde su propio commit sin correr,
	@# con 36 comprobaciones de credenciales generadas, travesía de rutas y
	@# escritura a través de enlaces simbólicos. Ni saltada ni en rojo — es que
	@# no estaba. Y no lo veía nadie porque lo que se cuenta al final son las
	@# suites que SÍ se lanzaron.
	@# Se cruza la clase entera —los ficheros que hay— contra lo que el target
	@# 'test' invoca, que es la lección de la v1.2.8 con los glifos: comprobar
	@# el conjunto, no el nombre que se te ocurra.
	@missing=$$(comm -23 <(ls tests/*_test.sh | sort) \
	  <(sed -n '/^test:/,/^$$/p' Makefile | grep -o 'tests/[a-z0-9_]*_test\.sh' | sort)); \
	if [ -n "$$missing" ]; then \
	  echo "ERROR: estas suites existen y 'make test' no las ejecuta:"; \
	  echo "$$missing" | sed 's/^/  /'; exit 1; \
	fi
	@echo "OK todas las suites están en 'make test'"

# shellcheck aborta al imprimir un aviso con acentos si la configuracion
# regional no es UTF-8, y en cron o systemd LANG suele venir vacia.
lint:
	LC_ALL=C.UTF-8 shellcheck -S warning -s bash orbit install.sh tests/*.sh

test: check lint
	bash tests/detect_test.sh
	bash tests/unit_test.sh
	bash tests/subcmd_test.sh
	bash tests/json_test.sh
	bash tests/cli_test.sh
	bash tests/top_test.sh
	bash tests/metrics_test.sh
	bash tests/traffic_test.sh
	bash tests/new_test.sh
	bash tests/interactive_test.sh
	bash tests/recover_test.sh
	bash tests/backup_test.sh
	bash tests/logs_test.sh
	bash tests/exec_test.sh
	bash tests/env_test.sh
	bash tests/nginx_test.sh
	bash tests/systemd_test.sh
	bash tests/isolate_test.sh
	bash tests/init_test.sh
	bash tests/provision_test.sh
	bash tests/install_test.sh
	bash tests/ui_test.sh
	bash tests/doctorfix_test.sh
	bash tests/python_test.sh
	bash tests/redirect_test.sh
	bash tests/maintenance_test.sh
	bash tests/watch_test.sh
	bash tests/notify_test.sh
	bash tests/autodeploy_test.sh
	bash tests/queue_test.sh
	bash tests/deploy_test.sh
	bash tests/clone_test.sh
	bash tests/i18n_test.sh

# Como 'test', pero un verde tiene que significar que se ha probado todo.
#
# Varias suites se saltan solas cuando les falta una herramienta y lo dicen en
# una linea que se pierde entre mil: sin rsync no corre el ciclo de despliegue,
# sin nginx ni php-fpm no se validan los vhosts, sin jq no se comprueba el
# contrato --json. La diferencia son 1.662 comprobaciones contra 2.447 —dos
# tercios— y un verde por ese motivo es peor que no tener pruebas, porque
# afirma algo que no ha comprobado. La cifra esta medida apartando jq, rsync,
# nginx y php-fpm del PATH, no estimada: las dos que habia aqui antes se
# habian quedado atras y nadie suma la columna.
#
# Esto es lo que ejecuta CI. En tu maquina 'make test' sigue valiendo: alli
# saltarse la parte de nginx mientras tocas otra cosa es razonable.
test-strict:
	@set -o pipefail; $(MAKE) --no-print-directory test 2>&1 | tee .test-output; \
	rc=$$?; \
	if grep -qi 'me salto' .test-output; then \
	  echo; echo "Estas comprobaciones NO se han ejecutado:"; \
	  grep -i 'me salto' .test-output | sed 's/^/  /'; \
	  echo; echo "Instala lo que falte: rsync jq nginx php-fpm"; \
	  echo "(el paquete de php-fpm lleva la version dentro: php8.3-fpm en"; \
	  echo " Ubuntu 24.04, php8.2-fpm en Debian 12 — decir una sola manda a"; \
	  echo " la mitad de la gente a instalar un paquete que no existe)"; \
	  rm -f .test-output; exit 1; \
	fi; \
	rm -f .test-output; \
	exit $$rc

install:
	sudo bash install.sh
