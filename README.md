# Root NB6VAC
J'ai récemment fait l'acquisition d'une NB6VAC achetée sur un site connu de seconde main et, comme projet personnel, j'ai essayé d'obtenir un accès root et, si possible, de pouvoir installer un OS custom.
Cette box m'a très souvent posé problème lors de mes précédents abonnements SFR (changé 4 fois en 1 an), alors j'ai décidé de prendre ma revanche.
Spoiler : J'ai l'accès root, mais il est impossible de changer d'OS sans changer le MCU (qui contrôle le secure boot et l'intégrité du kernel).
Je détaillerai à la fin du post comment il serait possible de changer d'OS.

Les commandes ont été exécutées sur un système GNU/Linux. Elles peuvent peut-être fonctionner sous macOS, mais il faudra trouver un équivalent pour Windows (ou utiliser WSL).

Pour des raisons de lisibilité et pour rendre le post le plus compréhensible possible, j'ai volontairement omis beaucoup d'informations, mais si besoin, je les ajouterai dans un autre post dans ce topic.

## Flashage
Il faudra un serveur TFTP (`dnsmasq` peut en gérer un) et un câble RJ45.

Après avoir indiqué le fichier de démarrage cible (le fichier joint), mettre sous tension la box en maintenant le bouton Wi-Fi sur le dessus de la box jusqu'à ce qu'il clignote, puis relâcher.
Si vous avez une connexion UART, vous pourrez voir la progression (ou l'échec) du flashage.
La box redémarrera automatiquement sur le nouveau firmware.

N.B : J'ai branché la NB6VAC en LAN via le port 4 de la box. Je ne sais pas si cela a une importance, mais je préfère le préciser.

## Méthode simple
Dans le repo, il y a un fichier `root.sh`. L'utilisation est assez simple, il faut l'exécuter avec le fichier (ou le nom) de la version souhaitée et le fichier de sortie.

## Méthode moins simple
### UART
Premièrement, il faut avoir un accès UART. Sur le bas de la carte mère se trouvent 4 broches UART (NE PAS BRANCHER LE 3.3V). On peut y brancher un adaptateur vers USB et le commander avec `minicom` ou `screen` avec un bauds de 115200.
Utilisez `minicom -D /dev/ttyUSB0 115200` (requiert les privilèges super-admin).

NOTE : J'avais fait un PoC, mais il n'était pas propre, alors les étapes suivantes sont partiellement issues du README de dougy147 sur GitHub, qui est bien plus détaillé que ce que j'aurais fait. Son travail m'a aussi permis de finaliser un point manquant du mien : reconstruire l'image finale.
Nous avons fait ce travail quasiment en même temps mais indépendamment l'un de l'autre. Sa solution était bien plus concluante que la mienne, alors j'ai fusionné nos deux solutions pour donner les étapes suivantes.

### Création d'un firmware avec un mot de passe personnalisé
Nous ne connaissons pas le mot de passe root et essayer de le casser prendrait beaucoup de temps. Une solution plus simple serait de créer une image flashable personnalisée avec notre mot de passe à la place de celui de SFR.
Pour cela, il faudra télécharger le bootloader et le firmware de la NB6VAC (le bootloader nous servira à créer l'image finale).

Premièrement, il faut extraire le rootfs du fichier brut, puis le monter sur notre système pour pouvoir accéder à ses fichiers et modifier `/etc/shadow`, réassembler l'image et la fusionner avec le bootloader pour avoir une image complète.

Seul le kernel est signé, ce qui fait qu'on peut changer les données du rootfs sans problème.

#### Étapes
1. Téléchargez l'avant-dernier firmware. La version `4.0.46` existe, mais je ne l'ai pas testée car la box était en `4.0.45d`.
```bash
wget -O NB6VAC-MAIN-R4.0.45d "https://ncdn.nb4dsl.neufbox.neuf.fr/nb6vac_Version%204.0.45d/NB6VAC-MAIN-R4.0.45d" --no-check-certificate
```

2. Installez ces dépendances
	1. binwalk
	3. make (`build-essential` sur Debian, `base-devel` sur ArchLinux)
	7. openssl
	8. mtd-utils
	9. python3
		1. ubi_reader

3. Retirez les 20 derniers octets contenant le check CRC32 à la fin du firmware (nous le rajouterons après nos modifications).

```bash
mkdir -p extract-wfi
cd extract-wfi
wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-extract/wfi-tag-extract.c
wget -q https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-extract/Makefile
make

cd ../
./extract-wfi/wfi-tag-extract -i NB6VAC-MAIN-R4.0.45d -o "NB6VAC-MAIN-R4.0.45d-no-wfi"
```

4. Extraire les images JFFS2 et UBI du firmware
```bash
# Début de l'image UBI
CUT_SECTION=$(binwalk "NB6VAC-MAIN-R4.0.45d-no-wfi" | grep UBI | awk '{print $1}')

# Extrait l'image JFFS2
dd if="NB6VAC-MAIN-R4.0.45d-no-wfi" of=jffs2.bin count=${CUT_SECTION} bs=1 status=none

# Extrait l'image UBI
dd if="NB6VAC-MAIN-R4.0.45d-no-wfi" of=ubi.ubi skip=${CUT_SECTION} bs=1 status=none
```

5. Simule la NAND de la box avec `nandsim`
```bash
modprobe nandsim first_id_byte=0xef second_id_byte=0xf1 third_id_byte=0x00 fourth_id_byte=0x95 parts=1,259,259,496,8
```

6. Choix de la partition rootfs
`cat /proc/mtd`
```bash
dev:    size   erasesize  name  
mtd0: 08000000 00020000 "NAND 128MiB 3,3V 8-bit"  
mtd1: 00020000 00020000 "NAND simulator partition 0"  
mtd2: 02060000 00020000 "NAND simulator partition 1" # Backup
mtd3: 02060000 00020000 "NAND simulator partition 2" # Principal
mtd4: 03e00000 00020000 "NAND simulator partition 3"  
mtd5: 00100000 00020000 "NAND simulator partition 4"  
mtd6: 00020000 00020000 "NAND simulator partition 5"
```
Prenez `mtd3` ou `mtd2` selon la version où vous voulez changer le mot de passe.
Dans notre cas, nous prendrons la version principale, donc `mtd3`.

7. Charge les kernel modules UBI
```bash
modprobe ubifs
modprobe ubi
```

8. Monter l'image UBI
```bash
MTD_DEVICE=$(cat /proc/mtd | grep -i "NAND simulator partition 2" | awk '{print $1}' | sed "s/://")
MTD_DEVICE_NB=$(grep -Eo "[[:digit:]]+$" <<< "$MTD_DEVICE")

# Efface la partition mtd3 avant de monter
flash_erase /dev/${MTD_DEVICE} 0 259
nandwrite /dev/${MTD_DEVICE} ubi.ubi
ubiattach -O 2048 -m $MTD_DEVICE_NB -d $MTD_DEVICE_NB
mkdir -p /mnt/ubi
mount -t ubifs /dev/ubi${MTD_DEVICE_NB}_0 /mnt/ubi
```

Rendez-vous dans `/mnt/ubi` pour avoir accès au rootfs principal
```bash
ls -la /mnt/ubifs  
total 4  
drwxr-xr-x 15 p0slx p0slx 1184 23 janv.  2022 .  
drwxr-xr-x  5 root  root  4096 13 mai   14:32 ..  
drwxr-xr-x  2 root  root  3376 23 janv.  2022 bin  
drwxr-xr-x  2 root  root   160 23 janv.  2022 dev  
drwxr-xr-x 26 root  root  3680 23 janv.  2022 etc  
drwxr-xr-x  4 root  root  1576 23 janv.  2022 lib  
lrwxrwxrwx  1 root  root     8 23 janv.  2022 mnt -> /tmp/mnt  
drwxr-xr-x  2 root  root   160 23 janv.  2022 overlay  
drwxr-xr-x  2 root  root   160 23 janv.  2022 proc  
drwxr-xr-x  2 root  root   160 23 janv.  2022 rom  
drwxr-xr-x  2 root  root   160 23 janv.  2022 root  
lrwxrwxrwx  1 root  root     8 23 janv.  2022 run -> /var/run  
drwxr-xr-x  2 root  root  1712 23 janv.  2022 sbin  
drwxr-xr-x  2 root  root   160 23 janv.  2022 sys  
drwxrwxrwt  2 root  root   160 23 janv.  2022 tmp  
drwxr-xr-x  6 root  root   416 23 janv.  2022 usr  
lrwxrwxrwx  1 root  root     8 23 janv.  2022 var -> /tmp/var  
drwxr-xr-x  4 root  root   296 23 janv.  2022 www
```


9. Créer son mot de passe root
```bash
openssl passwd -6 -salt salt_lafibreinfo mon_mdp
# $6$salt_lafibreinfo$D3SzGLUOJPzWvsqcZlQGHcrQWO5Xse2ONzvKudaAhbiyxvS6uKoEbtu5ZZX3pJT.hy/GUTu8XYVG.Q/FtEVAf.

# Remplacer l'ancien hash dans `/mnt/ubi/etc/shadow` par notre hash
# Ancienne ligne
root:$6$4aPeJ3IPS5unYRi6$PRE.k.g30N8zSifGSD7351UFiThinMYqi8M6d79iOllC78q1LLCeppcXHF68dcV5sWFL4xXeBJPHsHrM1YUdl1:14550:0:99999:7:::

# Ça nous donnerais ça
root:$6$salt_lafibreinfo$D3SzGLUOJPzWvsqcZlQGHcrQWO5Xse2ONzvKudaAhbiyxvS6uKoEbtu5ZZX3pJT.hy/GUTu8XYVG.Q/FtEVAf.:14550:0:99999:7:::
```

10. Reconstruire l'image UBI
```bash
mkfs.ubifs -m 2048 -e 126976 -c 131072 -v -r /mnt/ubi -o new.ubi --compr="zlib"

# Créer un fichier `ubi.cfg` et insérer ce contenu
[ubifs]
mode=ubi
image=new.ubi
vol_id=0
vol_type=dynamic
vol_name="rootfs_ubifs"
vol_flags=autoresize
# ---

# Installer ubi_reader via pip (utiliser un venv si besoin)
pip3 install ubi_reader
IMG_SEQ_NB=$(ubireader_display_info NB6VAC-MAIN-R4.0.45d | grep "Sequence Num" | awk '{print $4}')


IMG_SEQ=$(ubireader_display_info "NB6VAC-MAIN-R4.0.45d" | grep -Eo "Sequence Num: .*" | sed "s/Sequence Num: //")
if [[ -z $IMG_SEQ ]]
then
	ubinize -O 2048 -p 128KiB -m 2048 -s 2048 -o new-new.ubi -v ubi.cfg
else
	ubinize -O 2048 -p 128KiB -m 2048 -s 2048 -o new-new.ubi -v ubi.cfg --image-seq=${IMG_SEQ}
fi
```

11. Fusionner les images
```bash
dd status=progress if=jffs2.bin of=new-fw bs=1 status=none
dd status=progress if=new-new.ubi of=new-fw bs=1 seek=$(stat -c %s jffs2.bin) status=none
```

12. Ajouter le CRC32
```bash
mkdir -p make-wfi
cd make-wfi
wget https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-mk/wfi-tag-mk.c

wget https://bazaar.launchpad.net/\~vcs-imports/openbox4/trunk/download/head:/firmware_3.x/tools/nb6v-wfi-tag-mk/Makefile

make
cd ../

# Fichier final nommé NB6VAC-MAIN-R4.0.47 mais le nom n'a pas d'importance
# car on n'a pas changé le numéro de version interne.
./make-wfi/wfi-tag-mk -i new-fw -o NB6VAC-MAIN-R4.0.47
```

13. Nettoyage
```bash
umount /mnt/ubi
ubidetach -m "$MTD_DEVICE_NB"
modprobe -r nandsim
rm -rf "NB6VAC-MAIN-R4.0.45d-no-wfi" \
	jffs2.bin \
	ubi.ubi \
	new-ubi.ubi \
	ubi.cfg \
	new-new.ubi \
	new-fw
```

Il ne reste plus qu'à mettre l'image sur le serveur TFTP.
## Secure boot
La puce utilisée sur la NB6VAC est un OTP MCU C8051T634 de chez Silicon Labs.
Un dump est possible, mais il manque beaucoup de morceaux car les endroits intéressants sont protégés en lecture/écriture.
Il n'est pas possible de réinitialiser les bits gérant les droits de lecture et d'écriture, car la puce est une puce OTP (one-time programmable), donc programmable une seule fois.
La seule solution viable serait d'acheter une puce et de la programmer soi-même.

`c2tool` est un bon outil pour programmer ces puces et m'a été utile pour essayer de lire le MCU.

Je n'ai pas fait plus de recherches, car je ne vois pas comment faire autrement que par le remplacement de la puce (peut être glitcher la puce ?).
Le changement d'OS dépend uniquement du bypass de cette puce.
