#!/bin/bash

# =========================================================================
# PROYECTO: SERVIDOR DEDICADO OPENARENA CON RANKING WEB PERSISTENTE
# SCRIPT DE IMPLEMENTACIÓN COMPLETA (LUBUNTU / BASH)
# =========================================================================

# --- VARIABLES DE ENTORNO ---
SERVER_IP="192.168.0.86" # IP DE REFERENCIA DE LA MÁQUINA HOST/MV
GAME_PORT="27960"
WEB_ROOT="/var/www/html"
DB_PATH="${WEB_ROOT}/ranking.db"
PARSER_PATH="${WEB_ROOT}/parser.php"
RANKING_PATH="${WEB_ROOT}/ranking.php"
TIMESTAMP_FILE="${WEB_ROOT}/last_read_timestamp.txt"

# Función de Mensaje para la consola
log_msg() {
    echo -e "\n--- [INFO] $1"
    echo -e "----------------------------------------------------------"
}

# --- 1. INSTALACIÓN Y CONFIGURACIÓN DE SERVICIOS BASE ---
log_msg "FASE 1: Instalación de Dependencias y Stack Web (Apache/PHP/SQLite)"

sudo apt update -y
sudo apt install openssh-server -y

# Instalación del Servidor de Juego y Componentes Web
sudo apt install openarena-server apache2 php libapache2-mod-php php-sqlite3 sqlite3 -y

log_msg "Configurando Firewall (UFW) para acceso"
# Permite tráfico de juego (27960) y web (80)
sudo ufw allow from 192.168.0.0/24 to any port ${GAME_PORT} proto udp
sudo ufw allow 'Apache'
sudo ufw --force enable

log_msg "Reiniciando Apache para aplicar módulos PHP"
sudo systemctl restart apache2


# --- 2. CONFIGURACIÓN DEL SERVIDOR DE JUEGO (OPENARENA) ---
log_msg "FASE 2: Configuración del Motor (Rotación y Logging)"

SERVER_CFG_PATH="/etc/openarena-server/server.cfg"

# Detiene el servidor para asegurar que la edición del CFG sea efectiva
sudo systemctl stop openarena-server

# Crea el contenido del archivo server.cfg con la solución de rotación encadenada
log_msg "Creando archivo server.cfg con la solución de rotación vstr"
sudo cat << EOF | sudo tee ${SERVER_CFG_PATH} > /dev/null
/////////////////////////////////////////////////////////////////////////////
// CONFIGURACIÓN DE IDENTIDAD Y LOGS (CRÍTICA PARA EL RANKING)
/////////////////////////////////////////////////////////////////////////////
set sv_hostname "Servidor FFA RÁPIDO Y FIABLE (Rotación Forzada)"
set dedicated "2"
set sv_maxclients "10" 
set rcon_password ""
set logfile "1" // ACTIVA LOGS DETALLADOS para journalctl

/////////////////////////////////////////////////////////////////////////////
// REGLAS DE PARTIDA: TODOS CONTRA TODOS (FFA)
/////////////////////////////////////////////////////////////////////////////
set g_gametype "0" 
set timelimit "4"
set fraglimit "20"
set bot_skill "1" 
set bot_minplayers "10" 

/////////////////////////////////////////////////////////////////////////////
// ROTACIÓN DE MAPAS (MÉTODO DE ENCADENAMIENTO FIABLE)
/////////////////////////////////////////////////////////////////////////////
// Define los pasos del ciclo de rotación, asegurando que 'nextmap' siempre apunte al siguiente vstr.
set d1 "map oa_dm2; set nextmap vstr d2"
set d2 "map oa_dm4; set nextmap vstr d3"
set d3 "map oa_dm5; set nextmap vstr d4"
set d4 "map oa_dm6; set nextmap vstr d5"
set d5 "map oa_dm7; set nextmap vstr d1" // Reinicia el ciclo

// g_doNextMap se ejecuta al final de la partida para forzar la rotación.
set g_doNextMap "vstr d1"
map oa_dm1 // Mapa inicial
EOF


# --- 3. CONFIGURACIÓN DEL SISTEMA DE RANKING (PHP/SQLITE) ---
log_msg "FASE 3: Creación de Estructura de DB y Scripts Web"

# Asegura que el usuario web tiene permisos sobre el directorio web
sudo chown -R www-data:www-data ${WEB_ROOT}

# 1. Crear la Base de Datos SQLite y la Tabla
log_msg "Creando la tabla 'stats' y asegurando permisos para Apache"
if [ -f "${DB_PATH}" ]; then
    sudo rm "${DB_PATH}" # Limpia base de datos anterior
fi

sudo sqlite3 "${DB_PATH}" "CREATE TABLE stats (
    id INTEGER PRIMARY KEY, 
    killer TEXT NOT NULL, 
    victim TEXT NOT NULL, 
    weapon TEXT, 
    kill_time INTEGER
);"
sudo chown www-data:www-data "${DB_PATH}"


# 2. Crear el Script Analizador (parser.php)
log_msg "Creando script parser.php con lógica de gestión de marca de tiempo"
sudo cat << 'EOF' | sudo tee ${PARSER_PATH} > /dev/null
<?php
// SCRIPT ANALIZADOR DE LOGS (PARSER.PHP)
// Utiliza un archivo de marca de tiempo para evitar la duplicación de registros (Kills).

// --- CONFIGURACIÓN DE RUTAS ---
$db_path = '/var/www/html/ranking.db';
$timestamp_file = '/var/www/html/last_read_timestamp.txt'; 
    
// 1. OBTENER LA ÚLTIMA MARCA DE TIEMPO LEÍDA para evitar re-lectura
if (file_exists($timestamp_file)) {
    $last_read_timestamp = trim(file_get_contents($timestamp_file));
    // El formato '@' es para que journalctl lea desde un timestamp UNIX específico.
    $since_clause = is_numeric($last_read_timestamp) ? "--since @" . $last_read_timestamp : "--since '1 minute ago'";
} else {
    $since_clause = "--since '1 minute ago'";
}

// 2. COMANDO PARA LEER SÓLO LOS LOGS NUEVOS
$log_command = "journalctl -u openarena-server {$since_clause} | grep 'Kill:'";
    
// --- CONEXIÓN A LA BASE DE DATOS ---
try {
    $db = new PDO("sqlite:$db_path");
    $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (PDOException $e) {
    error_log("OpenArena Parser DB Error: " . $e->getMessage());
    die();
}

// 3. PROCESAMIENTO DEL LOG
$output = shell_exec($log_command);
$lines = explode("\n", trim($output));
$pattern = '/Kill:\s+\d+\s+\d+\s+\d+:\s+(.*)\s+killed\s+(.*)\s+by\s+(.*)/i';
$inserted_count = 0;
$current_timestamp = time(); 
$stmt = $db->prepare("INSERT INTO stats (killer, victim, weapon, kill_time) VALUES (:killer, :victim, :weapon, :kill_time)");

foreach ($lines as $line) {
    if (empty($line)) continue;
        
    if (preg_match($pattern, $line, $matches)) {
        $killer = trim($matches[1]);
        $victim = trim($matches[2]);
        // $weapon = trim($matches[3]); // Se omite para simplificar el modelo
        
        // Lógica de desambiguación: Suicidios se marcan como 'WORLD'
        if (strtolower($killer) === strtolower($victim)) {
             $killer = 'WORLD';
        }
        
        // Solo insertamos si el asesino no es 'WORLD' (para las Kills)
        if (strtolower($killer) === 'world' || empty($killer)) {
             // Esta lógica se maneja mejor en el ranking.php, insertamos todo.
        }

        $stmt->bindParam(':killer', $killer);
        $stmt->bindParam(':victim', $victim);
        $stmt->bindParam(':weapon', $weapon);
        $stmt->bindParam(':kill_time', $kill_time);
            
        try {
            $stmt->execute();
            $inserted_count++;
        } catch (PDOException $e) {
            // Ignoramos errores de duplicados si ocurren
        }
    }
}

// 4. GUARDAR LA MARCA DE TIEMPO para la próxima ejecución
if ($inserted_count > 0 || !file_exists($timestamp_file)) {
    file_put_contents($timestamp_file, $current_timestamp);
}
?>
EOF


# 4. Crear el Script de Ranking Web (ranking.php)
log_msg "Creando script ranking.php (Interfaz Web)"
sudo cat << 'EOF' | sudo tee ${RANKING_PATH} > /dev/null
<?php
// --- CONFIGURACIÓN DE BASE DE DATOS ---
$db_path = '/var/www/html/ranking.db';

// --- CONEXIÓN Y CONSULTA SQL ---
$ranking = [];
$error = null;

try {
    $db = new PDO("sqlite:$db_path");
    $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

    // Consulta SQL: Calcula Kills y Deaths y excluye 'WORLD'
    $query = "
        SELECT
            killer,
            -- Suma total de kills (el jugador es el asesino, NO es 'WORLD')
            SUM(CASE WHEN killer NOT IN ('WORLD') THEN 1 ELSE 0 END) AS total_kills,
            
            -- Muertes totales (cuando el jugador es la víctima)
            (SELECT COUNT(*) FROM stats AS t2 WHERE t2.victim = T1.killer) AS total_deaths
        FROM stats AS T1
        GROUP BY killer
        HAVING killer NOT IN ('WORLD', '<world>') 
        ORDER BY total_kills DESC, 
                 -- Calcula el ratio K/D (si las muertes son 0, usamos 1 para evitar la división por cero)
                 (CAST(total_kills AS REAL) / NULLIF(CAST((SELECT COUNT(*) FROM stats AS t3 WHERE t3.victim = T1.killer) AS REAL), 0)) DESC;
    ";
    
    $result = $db->query($query);
    $ranking = $result->fetchAll(PDO::FETCH_ASSOC);

} catch (PDOException $e) {
    $error = "Error al cargar la base de datos o ejecutar consulta: " . htmlspecialchars($e->getMessage());
}
?>

<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="30">
    <title>Ranking OpenArena</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #1a1a1a; color: #f0f0f0; margin: 20px; }
        .container { background-color: #2c2c2c; padding: 25px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0, 0, 0, 0.4); }
        h1 { color: #ff4500; border-bottom: 2px solid #555; padding-bottom: 10px; }
        table { width: 100%; border-collapse: collapse; margin-top: 25px; }
        th, td { border: 1px solid #444; padding: 12px; text-align: center; }
        th { background-color: #333; color: #fff; text-transform: uppercase; }
        tr:nth-child(even) { background-color: #383838; }
        .error { color: #ff0000; font-weight: bold; }
    </style>
</head>
<body>

<div class="container">
    <h1>🏆 Ranking de Jugadores OpenArena (FFA)</h1>
    <p>Datos actualizados automáticamente cada minuto.</p>
    
    <?php if ($error): ?>
        <p class="error">🚨 Error del Sistema: <?php echo $error; ?></p>
    <?php elseif (empty($ranking)): ?>
        <p>Aún no hay suficientes datos para generar el ranking. ¡Empieza a jugar!</p>
    <?php else: ?>
        <table>
            <thead>
                <tr>
                    <th>#</th>
                    <th>Jugador</th>
                    <th>Asesinatos (Kills)</th>
                    <th>Muertes (Deaths)</th>
                    <th>Ratio K/D</th>
                </tr>
            </thead>
            <tbody>
                <?php $rank = 1; foreach ($ranking as $row): ?>
                    <tr>
                        <td><?php echo $rank++; ?></td>
                        <td style="text-align: left; font-weight: bold;"><?php echo htmlspecialchars($row['killer']); ?></td>
                        <td><?php echo (int)$row['total_kills']; ?></td>
                        <td><?php echo (int)$row['total_deaths']; ?></td>
                        <td>
                            <?php 
                                $kills = (int)$row['total_kills'];
                                $deaths = (int)$row['total_deaths'];
                                echo number_format((float)$kills / max(1, $deaths), 2, '.', ''); 
                            ?>
                        </td>
                    </tr>
                <?php endforeach; ?>
            </tbody>
        </table>
    <?php endif; ?>
</div>

</body>
</html>
EOF

# 5. Configurar la Automatización (Cronjob)
log_msg "Configurando Tarea Cron para ejecutar el parser cada minuto"
(sudo crontab -l 2>/dev/null; echo "* * * * * /usr/bin/php ${PARSER_PATH} > /dev/null 2>&1") | sudo crontab -

log_msg "PROYECTO FINALIZADO. Servidor de Juego en: ${SERVER_IP}:${GAME_PORT}"
log_msg "Ranking Web en: http://${SERVER_IP}/ranking.php"
