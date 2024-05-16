#!/bin/bash
# Script de dougy147 (https://github.com/dougy147/NB6VAC)
# Amélioration par P0SlX (https://github.com/P0SlX)

# root-firmware-NB6VAC:
#       Convertir les firmwares officiels NB6VAC en firmwares accessibles en root.
#       Mot de passe root par défaut = root

set -e

# Root ?
if [ "$EUID" -ne 0 ]; then
    printf "ERREUR : Ce script doit être exécuté en tant que root.\n"
    exit 1
fi

dependencies=("ubiattach" "ubidetach" "grep" "modprobe" "dd" "flash_erase" "nandwrite" "mount" "openssl" "mkfs.ubifs" "sed" "chown" "make" "ubinize" "ubireader_display_info" "binwalk" "wget")
for dep in ${dependencies[@]}
do
    if [ ! $(which $dep 2>/dev/null) ]
    then
        missing=true
        printf "ATTENTION : dépendance manquante '%s'\n" "$dep"
    fi
done
if [ -n "$missing" ]
then
    printf "ERREUR : veuillez installer les dépendances manquantes.\n"
    exit 1
fi

usage() {
    printf "UTILISATION : %s <firmware_officiel> [nom_fichier_sortie] [mot_de_passe]\n" "$0"
    printf "Exemple : %s NB6VAC-MAIN-R4.0.45d\n" "$0"
}


nettoyage() {
    umount "$UBIFS_DIR"  >/dev/null 2>&1 || true
    ubidetach -m "$MTD_DEVICE_NB" >/dev/null 2>&1 || true
    modprobe -r nandsim >/dev/null 2>&1 || true
    rm -rf "${FIRMWARE_OFFICIEL_BASE}-no-wfi" \
           jffs2-custom.bin \
           ubi-custom.ubi \
           new-ubi.img \
           tmp-ubinize.cfg \
           new-ubi-custom.ubi \
           "${FIRMWARE_ROOT}-no-wfi" \
           "$UBIFS_DIR" 2>/dev/null || true
}


trap nettoyage EXIT
nettoyage

# Barre de progression
progression() {
    local current=$1
    local total=$2
    local step_name=$3
    local width=50
    local progress=$((current * width / total))
    printf "\r\033[2K[" # Efface la ligne avant d'imprimer
    for ((i=0; i<progress; i++)); do printf "#"; done
    for ((i=progress; i<width; i++)); do printf " "; done
    printf "] %d/%d %s" "$current" "$total" "$step_name"
}

# Liste des versions de firmware possibles
valid_versions=("4.0.16" "4.0.17" "4.0.18" "4.0.19" "4.0.20" "4.0.21" "4.0.35" "4.0.39" "4.0.40" "4.0.41" "4.0.42" "4.0.43" "4.0.44b" "4.0.44c" "4.0.44d" "4.0.44e" "4.0.44f" "4.0.44i" "4.0.44j" "4.0.44k" "4.0.45" "4.0.45c" "4.0.45d" "4.0.46")

# Extraction de la version du firmware
FIRMWARE=$1
FIRMWARE_VERSION=$(echo "$FIRMWARE" | grep -oP '(?<=NB6VAC-MAIN-R)[\d\.]+[a-z]*')

# Vérification de la version du firmware
if [[ ! " ${valid_versions[@]} " =~ " $FIRMWARE_VERSION " ]]
then
    printf "ERREUR : version de firmware invalide.\nExemple de version valide : NB6VAC-MAIN-R4.0.45d\n"
    exit 1
fi

FIRMWARE_OFFICIEL="NB6VAC-MAIN-R${FIRMWARE_VERSION}"
FIRMWARE_OFFICIEL_BASE=$(basename "$FIRMWARE_OFFICIEL")
FIRMWARE_ROOT=${2:-$FIRMWARE_OFFICIEL_BASE-root}
PASSWORD=${3:-root}

if [[ -z "$3" ]]
then
    printf "INFO : Aucun mot de passe spécifié, utilisation du mot de passe par défaut : 'root'.\n"
fi

TOTAL_ETAPES=7
ETAPE_COURANTE=0

# Téléchargement du firmware si non trouvé localement
if [[ ! -f "$FIRMWARE_OFFICIEL" ]]
then
    TOTAL_ETAPES=$((TOTAL_ETAPES + 1))
    ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
    printf "INFO : Firmware '%s' non trouvé localement.\n" "$FIRMWARE_OFFICIEL"
    progression $ETAPE_COURANTE $TOTAL_ETAPES "Téléchargement du firmware officiel"
    wget -q -O "$FIRMWARE_OFFICIEL" "https://ncdn.nb4dsl.neufbox.neuf.fr/nb6vac_Version%20${FIRMWARE_VERSION}/NB6VAC-MAIN-R${FIRMWARE_VERSION}" --no-check-certificate
    if [[ $? -ne 0 ]]
    then
        printf "ERREUR : Échec du téléchargement du firmware '%s'.\n" "$FIRMWARE_OFFICIEL"
        exit 1
    fi
fi


# Étape 1 : Extraction du WFI du firmware officiel
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Extraction du WFI du firmware officiel"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
if [ ! -f ./extract-wfi/wfi-tag-extract ]
then
    mkdir -p extract-wfi
    pushd ./extract-wfi/ >/dev/null 2>&1
    wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-extract/wfi-tag-extract.c
    wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-extract/Makefile
    make >/dev/null 2>&1
    popd >/dev/null 2>&1
fi
./extract-wfi/wfi-tag-extract -i "${FIRMWARE_OFFICIEL}" -o "${FIRMWARE_OFFICIEL_BASE}-no-wfi" >/dev/null 2>&1


# Étape 2 : Séparation de JFFS2 et UBI du firmware officiel
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Séparation de JFFS2 et UBI du firmware officiel"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
CUT_SECTION=$(binwalk "${FIRMWARE_OFFICIEL_BASE}-no-wfi" 2>/dev/null | grep UBI | awk '{print $1}')
if [[ -z $CUT_SECTION || $CUT_SECTION = 0 ]]
then
    printf "\nERREUR : impossible de trouver la section UBI dans %s\n" "${FIRMWARE_OFFICIEL}"
    exit 1
fi
dd if="${FIRMWARE_OFFICIEL_BASE}-no-wfi" of=jffs2-custom.bin count=${CUT_SECTION} bs=1 status=none
dd if="${FIRMWARE_OFFICIEL_BASE}-no-wfi" of=ubi-custom.ubi skip=${CUT_SECTION} bs=1 status=none


# Étape 3 : Montage de l'image UBI
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Montage de l'image UBI"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
modprobe nandsim first_id_byte=0xef  \
                   second_id_byte=0xf1 \
                   third_id_byte=0x00  \
                   fourth_id_byte=0x95 \
                   parts=1,259,259,496,8 >/dev/null 2>&1

MTD_DEVICE=$(cat /proc/mtd | grep -i "NAND simulator partition 2" | awk '{print $1}' | sed "s/://")
MTD_DEVICE_NB=$(grep -Eo "[[:digit:]]+$" <<< "$MTD_DEVICE")
if [[ -z $MTD_DEVICE || -z $MTD_DEVICE_NB || ! $(grep "mtd" <<< "$MTD_DEVICE") ]]
then
    printf "\nERREUR : impossible de trouver l'ID de périphérique MTD pour charger le système de fichiers UBI.\n"
    exit 1
fi

modprobe ubifs >/dev/null 2>&1
modprobe ubi >/dev/null 2>&1
flash_erase /dev/${MTD_DEVICE} 0 259 >/dev/null 2>&1
nandwrite /dev/${MTD_DEVICE} ubi-custom.ubi >/dev/null 2>&1
ubiattach -O 2048 -m $MTD_DEVICE_NB -d $MTD_DEVICE_NB >/dev/null 2>&1

UBIFS_DIR=$(mktemp -d)
mount -t ubifs /dev/ubi${MTD_DEVICE_NB}_0 $UBIFS_DIR >/dev/null 2>&1


# Étape 4 : Changement du mot de passe root dans le système de fichiers UBI monté
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Changement du mot de passe root dans le système de fichiers UBI"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
pushd $UBIFS_DIR >/dev/null 2>&1
HASH=$(openssl passwd -6 -salt d0u6y147S41t4nDp3pp3r "${PASSWORD}")
sed -i "s#^root.*#root:${HASH}:14550:0:99999:7:::#" "${UBIFS_DIR}/etc/shadow"
popd >/dev/null 2>&1


# Étape 5 : Reconstruction d'une image UBI à partir du système de fichiers
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Reconstruction d'une image UBI à partir du système de fichiers"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
mkfs.ubifs -m 2048 -e 126976 -c 131072 -v -r "${UBIFS_DIR}" -o new-ubi.img --compr="zlib" >/dev/null 2>&1
chown $USER new-ubi.img

cat > tmp-ubinize.cfg << EOF
[ubifs]
mode=ubi
image=new-ubi.img
vol_id=0
vol_type=dynamic
vol_name="rootfs_ubifs"
vol_flags=autoresize
EOF

IMG_SEQ=$(ubireader_display_info "$FIRMWARE_OFFICIEL" | grep -Eo "Sequence Num: .*" | sed "s/Sequence Num: //")
if [[ -z $IMG_SEQ ]]
then
    ubinize -O 2048 -p 128KiB -m 2048 -s 2048 -o new-ubi-custom.ubi -v tmp-ubinize.cfg >/dev/null 2>&1
else
    ubinize -O 2048 -p 128KiB -m 2048 -s 2048 -o new-ubi-custom.ubi -v tmp-ubinize.cfg --image-seq=${IMG_SEQ} >/dev/null 2>&1
fi


# Étape 6 : Fusion du JFFS2 d'origine avec le nouvel UBI
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Fusion du JFFS2 d'origine avec le nouvel UBI"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
dd if=jffs2-custom.bin of="${FIRMWARE_ROOT}-no-wfi" bs=1 status=none
dd if=new-ubi-custom.ubi of="${FIRMWARE_ROOT}-no-wfi" bs=1 seek=$(du -b jffs2-custom.bin | awk '{print $1}') status=none


# Étape 7 : Ajout des nouvelles balises WFI
ETAPE_COURANTE=$((ETAPE_COURANTE + 1))
NOM_ETAPE="Ajout des nouvelles balises WFI"
progression $ETAPE_COURANTE $TOTAL_ETAPES "$NOM_ETAPE"
if [ ! -f ./make-wfi/wfi-tag-mk ]
then

    mkdir -p make-wfi
    pushd ./make-wfi/ >/dev/null 2>&1
    wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v2-wfi-tag-mk/wfi-tag-mk.c
    wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v2-wfi-tag-mk/Makefile
    make >/dev/null 2>&1
    popd >/dev/null 2>&1
fi
./make-wfi/wfi-tag-mk -i "${FIRMWARE_ROOT}-no-wfi" -o "${FIRMWARE_ROOT}" >/dev/null 2>&1

printf "\nINFO : '%s' a été créé avec succès.\n" "${FIRMWARE_ROOT}"

nettoyage

# Dernière modification : 2024.05.16
