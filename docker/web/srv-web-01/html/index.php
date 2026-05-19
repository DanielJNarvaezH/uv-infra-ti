<?php
// Portal ciudadano — Unidad para la Atención y Reparación Integral a las Víctimas
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="es-CO">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Unidad para las Víctimas — Portal Ciudadano</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }
        .header { background: #003366; color: white; padding: 1rem 2rem; }
        .header h1 { margin: 0; font-size: 1.5rem; }
        .container { max-width: 900px; margin: 2rem auto; padding: 2rem; background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h2 { color: #003366; }
        .info { background: #e8f4f8; padding: 1rem; border-left: 4px solid #003366; margin: 1rem 0; }
        code { background: #eee; padding: 2px 6px; border-radius: 4px; }
        footer { text-align: center; color: #666; margin-top: 2rem; font-size: 0.9rem; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Unidad para las Víctimas — Portal Ciudadano</h1>
    </div>
    <div class="container">
        <h2>Bienvenido</h2>
        <p>Este es el portal ciudadano de la <strong>Unidad para la Atención y Reparación Integral a las Víctimas</strong>.</p>

        <div class="info">
            <strong>Servidor:</strong> srv-web-01<br>
            <strong>Entorno:</strong> <?php echo htmlspecialchars(gethostname()); ?><br>
            <strong>PHP:</strong> <?php echo phpversion(); ?><br>
            <strong>Hora del servidor:</strong> <?php echo date('Y-m-d H:i:s'); ?>
        </div>

        <p>A través de este portal podrás:</p>
        <ul>
            <li>Consultar información sobre el proceso de reparación integral.</li>
            <li>Acceder a caracterizaciones de procesos y políticas institucionales.</li>
            <li>Conocer los canales de atención a víctimas del conflicto armado.</li>
        </ul>
    </div>
    <footer>
        Universidad del Quindío — Semestre 2026-1 | Proyecto Infraestructura TI
    </footer>
</body>
</html>
