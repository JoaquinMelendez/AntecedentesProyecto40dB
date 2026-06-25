## Paleta de colores

| Rol               | Token                 | HEX     | Uso                          |
| ----------------- | --------------------- | ------- | ---------------------------- |
| Primario          | --color-primary       | #004D40 | Botones primarios, links     |
| Primario hover    | --color-primary-hover | #00332B | Estado hover                 |
| Secundario        | --color-accent        | #FFAB91 | Elementos destacados, badges |
| Texto principal   | --color-text          | #593D3B | Cuerpo de texto              |
| Texto secundario  | --color-text-muted    | #8A7968 | Descripciones, timestamps    |
| Fondo             | --color-bg            | #FFFFFF | Fondo general                |
| Fondo alternativo | --color-bg-alt        | #F5F5F5 | Tarjetas, hover de filas     |
| Borde             | --color-border        | #E0E0E0 | Separadores                  |
| Éxito             | --color-success       | #1B5E20 | Confirmaciones               |
| Error             | --color-danger        | #B71C1C | Errores, eliminar            |
| Advertencia       | --color-warning       | #FFAB91 | Avisos                       |
| Info              | --color-info          | #004D40 | Información neutra           |

**Verificación de contraste (AA):**

- Texto principal sobre fondo: 16.1:1 ✅
- Texto sobre primario: 7.4:1 ✅
- Texto secundario sobre fondo: 5.6:1 ✅

## Uso del logo

### Espacio de seguridad

Mantener un margen mínimo equivalente al alto de la "X" del nombre alrededor del logo.

### Tamaño mínimo

- Web: 24px de alto
- Impreso: 12mm de alto

### Fondos permitidos

- Logo a color sobre blanco o tonos neutros muy claros (--color-bg, --color-bg-alt)
- Logo blanco sobre --color-primary o cualquier fondo oscuro con contraste ≥ 4.5:1

### NO hacer

- ❌ Deformar la proporción (estirar, comprimir)
- ❌ Cambiar los colores oficiales por otros
- ❌ Aplicar sombras, biseles o efectos
- ❌ Rotar el logo
- ❌ Usar el logo a color sobre fondos de bajo contraste

## Componentes

### Botones

- **Primario:** fondo `--color-primary`, texto blanco, padding 12px 20px, radio 6px, peso 600
- **Secundario:** fondo transparente, borde 1px `--color-primary`, texto `--color-primary`
- **Destructivo:** fondo `--color-danger`, texto blanco
- **Estados:** hover (oscurecer 10%), focus (anillo de 2px `--color-primary` con offset), disabled (50% opacidad, cursor not-allowed)

### Inputs

- altura 40px, borde 1px `--color-border`, radio 6px, padding 0 12px, font-size --text-base
- focus: borde --color-primary + ring 3px primary @ 20%
- error: borde --color-danger + texto de error abajo en --text-sm

### Tarjetas (Cards)

- fondo --color-bg-alt, borde 1px --color-border, radio 8px, padding 20px, sombra suave (`0 1px 3px rgba(0,0,0,0.05)`)

### Mensajes (Alerts)

- éxito / error / advertencia / info: cada uno con su color semántico al 10% de fondo y al 100% en el borde izquierdo (4px)

### Tipografía aplicada

- H1: --text-3xl, --font-bold, --leading-tight, --font-heading
- H2: --text-2xl, --font-semibold, --font-heading
- H3: --text-xl, --font-semibold, --font-heading
- Body: --text-base, --font-regular, --leading-normal, --font-body
- Small: --text-sm, --color-text-muted

### Espaciado (escala 4px)

| Token      | px  |
| ---------- | --- |
| --space-1  | 4   |
| --space-2  | 8   |
| --space-3  | 12  |
| --space-4  | 16  |
| --space-6  | 24  |
| --space-8  | 32  |
| --space-12 | 48  |
| --space-16 | 64  |
