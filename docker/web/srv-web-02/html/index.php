<?php
// RNI — Red Nacional de Información (comunicaciones con organizaciones externas)
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="es-CO">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RNI — Red Nacional de Información</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }
        .header { background: #005544; color: white; padding: 1rem 2rem; }
        .header h1 { margin: 0; font-size: 1.5rem; }
        .container { max-width: 900px; margin: 2rem auto; padding: 2rem; background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h2 { color: #005544; }
        .info { background: #e8f8f4; padding: 1rem; border-left: 4px solid #005544; margin: 1rem 0; }
        code { background: #eee; padding: 2px 6px; border-radius: 4px; }
        footer { text-align: center; color: #666; margin-top: 2rem; font-size: 0.9rem; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Red Nacional de Información (RNI)</h1>
    </div>
    <div class="container">
        <h2>Portal de Comunicaciones con Organizaciones Externas</h2>
        <p>Este portal gestiona la comunicación de la <strong>Unidad para las Víctimas</strong> con organizaciones nacionales e internacionales.</p>

        <div class="info">
            <strong>Servidor:</strong> srv-web-02<br>
            <strong>Entorno:</strong> <?php echo htmlspecialchars(gethostname()); ?><br>
            <strong>PHP:</strong> <?php echo phpversion(); ?><br>
            <strong>Hora del servidor:</strong> <?php echo date('Y-m-d H:i:s'); ?>
        </div>

        <p>Funciones principales:</p>
        <ul>
            <li>Intercambio seguro de información con entidades aliadas.</li>
            <li>Gestión de convenios y acuerdos de cooperación.</li>
            <li>Coordinación de programas de reparación integral.</li>
        </ul>
    </div>
    <footer>
        Universidad del Quindío — Semestre 2026-1 | Proyecto Infraestructura TI
    </footer>
</body>
</html>
