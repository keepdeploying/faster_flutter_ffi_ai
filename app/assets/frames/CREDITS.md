# Frame credits

Test frames for the classify demo and the benchmark. Each is a Wikimedia Commons photo, centre-cropped to 4:3 and resized to 640x480 JPEG (under 120 KB). The photos are only cropped, resized and re-encoded; nothing else is changed. Licences: CC0 and public domain need no credit; CC BY needs the credit below.

| File | Top label (MobileNet V1, float) | Source | Author | Licence |
| --- | --- | --- | --- | --- |
| `banana.jpg` | banana (1.00) | [Punti (Banana).jpg](https://commons.wikimedia.org/wiki/File:Punti_(Banana).jpg) | Elaine Mae Yon Jimin | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0) |
| `coffee_mug.jpg` | coffee mug (0.73) | [Coffee mugs cups.jpg](https://commons.wikimedia.org/wiki/File:Coffee_mugs_cups.jpg) | Jon Sullivan | [Public domain](https://commons.wikimedia.org/wiki/Commons:Licensing#Public_domain) |
| `golden_retriever.jpg` | golden retriever (0.99) | [Golden Retriever Chewing A Stick.jpg](https://commons.wikimedia.org/wiki/File:Golden_Retriever_Chewing_A_Stick.jpg) | Cheetyuh | [CC0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| `keyboard.jpg` | computer keyboard (0.80) | [Black Computer keyboard.jpg](https://commons.wikimedia.org/wiki/File:Black_Computer_keyboard.jpg) | Samiknoov | [CC0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| `orange.jpg` | orange (0.82) | [Citrus reticulata fruit 2009 G1.jpg](https://commons.wikimedia.org/wiki/File:Citrus_reticulata_fruit_2009_G1.jpg) | George Chernilevsky | [Public domain](https://commons.wikimedia.org/wiki/Commons:Licensing#Public_domain) |
| `pineapple.jpg` | pineapple (0.40) | [A Developing pineapple (Ananas comosus).jpg](https://commons.wikimedia.org/wiki/File:A_Developing_pineapple_(Ananas_comosus).jpg) | Victorpeter001 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0) |
| `pizza.jpg` | pizza (0.55) | [Pizza 15.jpg](https://commons.wikimedia.org/wiki/File:Pizza_15.jpg) | Kurt Kaiser | [CC0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| `school_bus.jpg` | school bus (1.00) | [Crusaders School Bus, Chalmette, Louisiana.jpg](https://commons.wikimedia.org/wiki/File:Crusaders_School_Bus,_Chalmette,_Louisiana.jpg) | Uncredited for National Park Service | [Public domain](https://commons.wikimedia.org/wiki/Commons:Licensing#Public_domain) |
| `strawberry.jpg` | strawberry (1.00) | [Close up of cut garden strawberry Fragaria ananassa.JPG](https://commons.wikimedia.org/wiki/File:Close_up_of_cut_garden_strawberry_Fragaria_ananassa.JPG) | Darkon X | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0) |
| `tabby_cat.jpg` | tabby (0.85) | [Tabby cat-3337027.jpg](https://commons.wikimedia.org/wiki/File:Tabby_cat-3337027.jpg) | pasja1000 | [CC0](http://creativecommons.org/publicdomain/zero/1.0/deed.en) |
| `teapot.jpg` | teapot (0.97) | [Teapot 2010 G1.jpg](https://commons.wikimedia.org/wiki/File:Teapot_2010_G1.jpg) | George Chernilevsky | [Public domain](https://commons.wikimedia.org/wiki/Commons:Licensing#Public_domain) |

Notes:

- `orange.jpg` shows mandarins; MobileNet calls them "orange".
- `coffee_mug.jpg` shows a mug with a printed company logo; the photo itself is the public-domain work listed above.
- Top labels were measured with the bundled model in Python (LiteRT) using the app's preprocessing rule (half-pixel bilinear to 224x224, RGB, [-1, 1]; see `../models/README.md`). Device results can differ by a few hundredths in confidence.
